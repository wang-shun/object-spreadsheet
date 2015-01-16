EJSONtoMongoFieldName = (x) ->
  # JSON may contain '.', which is special in Mongo field names, as part of a
  # floating point or string literal.  We need to escape it somehow.  '!' should
  # only appear as a character in a string literal, so if we replace it by its
  # escaped form, then we can use '!' to represent '.'.
  EJSON.stringify(x).replace('!', '\\x21').replace('.', '!')

EJSONfromMongoFieldName = (f) ->
  EJSON.parse(f.replace('!', '.'))

@rootColumnId = '_unit'

# Multisets unsupported for now: twindex removed.

@rootCellId = []
@cellIdParent = (cellId) -> cellId[0..-2]
@cellIdChild = (cellId, value) -> cellId.concat([value])
@cellIdLastStep = (cellId) -> cellId[cellId.length - 1]

# Now that we're no longer using custom classes, we might be able to use plain
# JSON, but we've written this already...

class EJSONKeyedMap
  constructor: ->
    # Future: Change to ECMAScript 6 Map when supported by all relevant JS
    # engines and CoffeeScript.
    @obj = {}
  wrapKey = (k) -> 'map_' + EJSON.stringify(k)
  unwrapKey = (k) ->
    try
      EJSON.parse(k.substr(4))
    catch e
      console.log('unwrapKey failed on', k)
      throw e

  get: (k) -> @obj[wrapKey(k)]
  set: (k, v) -> @obj[wrapKey(k)] = v
  delete: (k) -> delete @obj[wrapKey(k)]
  keys: -> unwrapKey(wk) for wk of @obj

class EJSONKeyedSet
  constructor: ->
    @map = new EJSONKeyedMap()
  has: (x) -> !!@map.get(x)
  add: (x) -> @map.set(x, true)
  delete: (x) -> @map.delete(x)
  elements: -> @map.keys()

class EJSONKeyedMapToSet
  constructor: ->
    @map = new EJSONKeyedMap()
  add: (k, v) ->
    s = @map.get(k)
    unless s?
      s = new EJSONKeyedSet()
      @map.set(k, s)
    s.add(v)
  delete: (k, v) ->
    s = @map.get(k)
    if s?
      s.delete(v)
      if s.elements().length == 0
        @map.delete(k)
  elementsFor: (k) -> @map.get(k)?.elements() ? []

# Column:
  #@parent: column ID
  #@children: array of column IDs, now in the user's desired order
  #@childByName: EJSONKeyedMap<name, column ID>
  #@orderToken: string (for now) or null
  #@name: string or null
  #@type: column ID
  #@cellName: string or null
  #@formula: some JSON data structure, or null

class EvaluationError

# The client should not need most of this code, but I don't want to fight with
# the load order right now. ~ Matt

@FAMILY_DATA_COLLECTION = 'familyData'
@COLUMN_COLLECTION = 'columns'

class Model

  # TODO: Indicate which methods are intended to be public!

  class CacheEntry  # local
    @IN_PROGRESS: 1
    @SUCCESS: 2
    @ERROR: 3

    constructor: () ->
      @state = CacheEntry.IN_PROGRESS
      # Only needed if we want to revalidate existing results.
      #@deps = []  # array of QFamilyId
      @content = null  # list of values, no duplicates (for now)

  #@state: EJSONKeyedMapToSet<QFamilyId, value>
  #@familyCache: EJSONKeyedMap<QFamilyId, CacheEntry>
  #@columns: EJSONKeyedMap<ColumnId, Column>

  initializeColumnTempData: (col) ->
    col.childByName = new EJSONKeyedMap()

  registerColumnWithParent: (col) ->
    parentColId = col.parent
    parentCol = @columns.get(parentColId)
    # XXX: Assert no duplicate names
    if col.name?
      parentCol.childByName.set(col.name, col._id)
    if col.cellName?
      parentCol.childByName.set(col.cellName, col._id)

  unregisterColumnWithParent: (col) ->
    parentColId = col.parent
    parentCol = @columns.get(parentColId)
    if col.name?
      parentCol.childByName.delete(col.name)
    if col.cellName?
      parentCol.childByName.delete(col.cellName)

  constructor: ->
    @publishers = []

    @columns = new EJSONKeyedMap()
    @state = new EJSONKeyedMapToSet()
    @familyCache = null

    # Load from DB.
    # Future: Need a way to make a temporary model for a transaction without reloading.
    for col in Columns.find().fetch()
      @columns.set(col._id, col)
      for cellIdStr of col.cells ? {}
        cellId = EJSONfromMongoFieldName(cellIdStr)
        @state.add({columnId: col._id, parentCellId: cellIdParent(cellId)},
                   cellIdLastStep(cellId))
      # Don't store a duplicate copy.  So, careful about writing col back to DB.
      delete col.cells
      @initializeColumnTempData(col)

    # Special case: create root column if missing.
    unless @columns.get(rootColumnId)?
      # None of the other properties should be used.
      col = {
        _id: rootColumnId
        children: []
        cells: {}
      }
      @columns.set(rootColumnId, col)
      Columns.insert(col)
      delete col.cells
      @initializeColumnTempData(col)

    # Now go back and link things up.
    for colId in @columns.keys()
      col = @columns.get(colId)
      # XXX: Validate each column (except root) has exactly one parent.
      for childId in col.children
        @columns.get(childId).parent = colId
      if colId != rootColumnId
        # XXX: Assert parent existence
        @registerColumnWithParent(col)
    # Future: validate that type usage is acyclic.

    for colId in @columns.keys()
      for publisher in @publishers
        @publishColumn(colId, publisher)

  getColumn: (columnId) ->
    # Treat as read-only and valid only until the model is next modified.
    # XXX: Replace by a real API.  At least the references will be easy to find.
    return @columns.get(columnId)

  parseTypeStr: (s) ->
    if /^_/.test(s)
      return s
    else
      colId = rootColumnId
      for n in s.split('.')
        # XXX: Maybe types should accept cellName only.
        colId = @getColumn(colId).childByName.get(n)
      return colId

  defineColumn: (parentId, name, type, cellName, formula) ->
    # Future: specify order rather than always at the end
    # Future: validate everything
    # Future: validate no name for type = _unit or _token
    @invalidateCache()
    thisId = Random.id()
    col = {
      _id: thisId
      parent: parentId
      name: name
      type: type
      cellName: cellName
      formula: formula
      children: []
      cells: {}
    }
    @columns.set(thisId, col)
    Columns.insert(col)
    # Silly... "cells" is for DB only.
    delete col.cells
    @initializeColumnTempData(col)
    parentCol = @columns.get(parentId)
    parentCol.children.push(thisId)
    # Meteor is nice for so many things, but not ORM...
    Columns.update(parentCol._id, {$set: {children: parentCol.children}})
    @registerColumnWithParent(col)

    for publisher in @publishers
      @publishColumn(thisId, publisher)
      @unpublishColumn(parentId, publisher)
      @publishColumn(parentId, publisher)

    return thisId

  deleteColumn: (columnId) ->
    # Assert not root
    col = @columns.get(columnId)
    if col.children.length
      throw new Error('Unimplemented: Deleting a column with children')
    # Assert col.childByName also empty
    unless col.formula?
      throw new Error('Unimplemented: Deleting a state column')
    parentCol = @columns.get(col.parent)
    parentCol.children.splice(parentCol.children.indexOf(columnId), 1)
    @unregisterColumnWithParent(col)
    @columns.delete(columnId)
    Columns.remove(columnId)
    for publisher in @publishers
      @unpublishColumn(columnId, publisher)

  # Future: API to reorder tokens
  writeState: (qFamilyId, value, present) ->
    # Future: Validate everything.
    cellId = cellIdChild(qFamilyId.parentCellId, value)
    @invalidateCache()
    mongoUpdateThing = {}
    mongoUpdateThing['cells.' + EJSONtoMongoFieldName(cellId)] = true
    if present
      @state.add(qFamilyId, value)
      Columns.update(qFamilyId.columnId, {$set: mongoUpdateThing})
    else
      @state.delete(qFamilyId, value)
      Columns.update(qFamilyId.columnId, {$unset: mongoUpdateThing})

  evaluateFamily1: (qFamilyId) ->
    col = @columns.get(qFamilyId.columnId)
    if col.formula?
      # TODO: Evaluate formula
      return []
    else
      # State column (there are no domain columns yet)
      return @state.elementsFor(qFamilyId)

  evaluateFamily: (qFamilyId) ->
    ce = @familyCache.get(qFamilyId)
    unless ce?
      ce = new CacheEntry()
      @familyCache.set(qFamilyId, ce)
      try
        ce.content = @evaluateFamily1(qFamilyId)
        ce.state = CacheEntry.SUCCESS
      catch e
        if e instanceof EvaluationError
          ce.state = CacheEntry.ERROR
        else
          throw e

    return ce

  readFamilyForFormula: (qFamilyId) ->
    ce = @evaluateFamily(qFamilyId)
    if ce.state == CacheEntry.SUCCESS
      return ce.content
    else
      # Includes CacheEntry.IN_PROGRESS, which means a newly detected cycle.
      # Future: 'Reference to CELL, which failed', precise cycle detection with
      # different message.
      throw new EvaluationError()

  readFamily: (qFamilyId) ->
    ce = @familyCache.get(qFamilyId)
    # Assert it has been evaluated (i.e., watches are correct).
    return ce.content

  evaluateAll: ->
    if @familyCache?
      return  # already valid
    @familyCache = new EJSONKeyedMap()

    evaluateSubtree = (qCellId) =>
      col = @columns.get(qCellId.columnId)
      for childColId in col.children
        ce = @evaluateFamily({columnId: childColId, parentCellId: qCellId.cellId})
        if ce.state == CacheEntry.SUCCESS
          for value in ce.content
            childQCellId = {columnId: childColId, cellId: cellIdChild(qCellId.cellId, value)}
            evaluateSubtree(childQCellId)

    # Future: Only evaluate what users are viewing.
    evaluateSubtree({columnId: rootColumnId, cellId: rootCellId})

    # Consider publishing as we go?
    for qFamilyId in @familyCache.keys()
      for publisher in @publishers
        @publishFamily(qFamilyId, publisher)

  unpublishFamily: (qFamilyId, publisher) ->
    publisher.removed(FAMILY_DATA_COLLECTION, EJSON.stringify(qFamilyId))

  publishFamily: (qFamilyId, publisher) ->
    publisher.added(FAMILY_DATA_COLLECTION, EJSON.stringify(qFamilyId),
                    {content: @familyCache.get(qFamilyId).content})

  unpublishColumn: (columnId, publisher) ->
    publisher.removed(COLUMN_COLLECTION, columnId)

  publishColumn: (columnId, publisher) ->
    col = @columns.get(columnId)
    x = {}
    for k, v of col when k != 'childByName'
      x[k] = v
    publisher.added(COLUMN_COLLECTION, columnId, x)

  invalidateCache: ->
    if @familyCache?
      for qFamilyId in @familyCache.keys()
        for publisher in @publishers
          @unpublishFamily(qFamilyId, publisher)
      @familyCache = null

  addPublisher: (publisher) ->
    @publishers.push(publisher)
    for columnId in @columns.keys()
      @publishColumn(columnId, publisher)
    if @familyCache?
      for qFamilyId in @familyCache.keys()
        @publishFamily(qFamilyId, publisher)
    publisher.ready()

  removePublisher: (publisher) ->
    @publishers.splice(@publishers.indexOf(publisher), 1)

if Meteor.isServer
  Meteor.startup () ->
    @model = new Model()
    if model.columns.keys().length == 1  # root column :/
      loadSampleData()
    model.evaluateAll()
  # Publish everything for now.
  # Future: Reduce amount of add/remove thrashing.
  Meteor.publish(null, () ->
    @onStop(() -> model.removePublisher(this))
    model.addPublisher(this)
  )
