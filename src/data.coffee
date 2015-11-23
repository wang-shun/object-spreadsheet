# XXX: The division of code between this file and common.coffee is not
# well-defined.  Define it and move things as necessary.

#COLUMN_COLLECTION = 'columns'
#CELLS_COLLECTION = 'cells'
# need them for publisher? maybe just use Columns._name, Cells._name?

scoped = (name, prop) -> Object.defineProperty(@, name, prop)

scoped('$$', {get: -> Tablespace.get()})
for coll in ['Columns', 'Cells', 'Views', 'Procedures']
  ((coll) ->  # Work around JavaScript variable capture semantics
    scoped(coll, {get: -> $$[coll]})
  )(coll)


class Tablespace extends ControlContext
  constructor: (@id) ->
    super()
    if Meteor.isServer
      # The constructor is called during Meteor method EJSON conversion, and
      # creating Mongo.Collections during that process causes various errors.
      # Defer until the control context is actually activated as part of the
      # Meteor method call.
      @do(@setupCollections)
    if Meteor.isClient
      # This is safe, and the client does not activate control contexts.
      @setupCollections()
      # Better ideas where to put this?  On the server, it's done in model.coffee.
      @formulaEngine = new FormulaEngine()

  setupCollections: () ->
    console.log "created Tablespace[#{@id}]"
    @Columns    = new Mongo.Collection "#{@id}:columns"
    @Cells      = new Mongo.Collection "#{@id}:cells"
    @Views      = new Mongo.Collection "#{@id}:views"
    @Procedures = new Mongo.Collection "#{@id}:procedures"
    if Meteor.isServer
      for collection in [@Columns,@Cells,@Views,@Procedures]
        @publish collection
      @Cells.allow { insert: (-> true), update: (-> true), remove: (-> true) }  # @@@ Matt will kill me

  publish: (collection) ->
    # Do not inline this into the same function as the loop over collections, or
    # the reference to "collection" from the publish function will see the wrong
    # value of the variable (insane JavaScript semantics).
    Meteor.publish collection._name, -> collection.find()

  subscribeAll: () ->
    for collection in [@Columns,@Cells,@Views]
      Meteor.subscribe collection._name

  runTransaction: (op) ->
    @run ->
      t = new Transaction
      t.begin()
      try
        ret = op()
        t.commit()
        ret
      catch e
        t.rollback()
        throw e
    
  typeName: -> 'Tablespace'
  toJSONValue: -> {@id}
  @fromJSONValue: (json) => @get json.id

EJSON.addType('Tablespace', Tablespace.fromJSONValue)

    
    
_toColumnId = (selector) ->
  selector._id ?
  if _.isRegExp(selector) then parseColumnRef(selector.source)[0]
  else selector

    
class CellId
  constructor: ({columnId, @cellId}) -> @columnId = _toColumnId(columnId)
  
  q: -> {@columnId, @cellId}
  
  parent: ->
    c = getColumn(@columnId)
    if c && c.parent?
      new CellId
        columnId: c.parent
        cellId: cellIdParent(@cellId)
      
  ancestors: ->
    c = @
    ancestors = []
    while c?
      ancestors.push(c)
      c = c.parent()
    ancestors
    
  value: (set, callback=->) -> 
    if set? then @remove(); @family().add(set, callback)
    else cellIdLastStep(@cellId)
  
  family: (columnId) ->
    if columnId?
      new FamilyId({columnId, @cellId})
    else
      new FamilyId({@columnId, cellId: cellIdParent(@cellId)})
      
  families: ->
    (@family(childId) for childId in getColumn(@columnId)?.children ? [])
    
  remove: (callback=->) -> @family().remove(@value(), callback)
  
  ref: -> new TypedSet(@columnId, set([@cellId]))
  

class FamilyId
  constructor: ({columnId, @cellId}) -> @columnId = _toColumnId(columnId)

  parent: -> # returns a qCellId
    c = getColumn(@columnId)
    if c && c.parent?
      new CellId
        columnId: c.parent
        cellId: @cellId
      
  ancestors: ->
    @parent().ancestors()
    
  read: -> Cells.findOne({column: @columnId, key: @cellId})
  
  # Ignores erroneous families.
  # FIXME: Review all callers and implement error propagation where appropriate.
  values: -> @read()?.values ? []
  
  type: -> Columns.findOne(@columnId).type
  
  typedValues: -> new TypedSet(@type(), set(@values()))
  
  child: (value) -> 
    new CellId({@columnId, cellId: cellIdChild(@cellId, value)})
  
  children: -> @values().map (v) => @child(v)
  
  # XXX: Should we change the database format so this is just a qFamilyId?
  selector: () -> {column: @columnId, key: @cellId}

  add: (value, callback=(->), consumePlaceholder=false) ->
    updates = {$addToSet: {values: value}}
    if consumePlaceholder && Cells.findOne(@selector())?.numPlaceholders
      updates.$inc = {numPlaceholders: -1}
    upsertOne(Cells, @selector(), updates, callback)
    @child(value)

  remove: (value, callback=->) ->
    # Why was updateOne needed? ~ Matt 2015-10-19
    #updateOne Cells, {column: @columnId, key: @cellId}, {$pull: {values: value}}, callback
    Meteor.call('recursiveDeleteStateCellNoInvalidate', $$,
                @columnId, cellIdChild(@cellId, value), callback)

  addPlaceholder: (callback=->) ->
    # If the field is initially absent, $inc treats it as 0.
    upsertOne(Cells, @selector(), {$inc: {numPlaceholders: 1}}, callback)

  removePlaceholder: (callback=->) ->
    if Cells.findOne(@selector())?.numPlaceholders   # XXX race
      updateOne(Cells, @selector(), {$inc: {numPlaceholders: -1}}, callback)


rootCell = CellId.ROOT = new CellId({columnId: rootColumnId, cellId: rootCellId})

allCellIdsInColumnIgnoreErrors = (columnId) ->
  if columnId == rootColumnId
    return [rootCellId]
  cellIds = []
  for family in Cells.find({column: columnId}).fetch() when family.values?
    for v in family.values
      cellIds.push(cellIdChild(family.key, v))
  return cellIds

# Helpers to access collections from the client, which is only allowed to select
# documents by ID.

updateOne = (collection, selector, modifier, callback) ->
  if (doc = collection.findOne(selector))?
    collection.update(doc._id, modifier, callback)
    
upsertOne = (collection, selector, modifier, callback) ->
  doc = collection.findOne(selector)
  if doc then id = doc._id
  else id = collection.insert(selector)
  collection.update(id, modifier, callback)
      


class CellsInMemory

  _cnt = 0
  _freshId = -> _cnt += 1 ; "cim.#{_cnt}"

  constructor: ->
    @byColumn = {}
    @byId = {}
    @recycle = new EJSONKeyedMap

  insert: (doc) ->
    #console.log "[insert(#{JSON.stringify doc})]"
    if !doc._id?
      doc._id = @mkId(doc)
    column = doc.column ; key = doc.key
    @byColumn[column] = byKey = @byColumn[column] ? new EJSONKeyedMap
    #**  assume !byKey.get(key)?  **#
    byKey.set(key, doc)
    @byId[doc._id] = doc
    doc._id

  mkId: (doc) ->
    if (rec = @recycle.get([doc.column, doc.key]))?
      rec
    else
      while @byId[fid = _freshId()]? then 0
      fid

  findOne: (query) ->
    if _.isString(query)
      @byId[query]
    else if (column = query.column)?
      byKey = @byColumn[column]
      if byKey?
        if (key = query.key)?
          byKey.get(key)
        else
          throw Error "unimplemented [findOne(query=#{JSON.stringify(query)})]"
      else
        undefined
    else
      throw Error "unimplemented [findOne(query=#{JSON.stringify(query)})]"

  find: (query) ->
    forEach: (cb) =>
      for _id, doc of @byId
        if doc.dirty == query.dirty
          cb(doc)

  update: (query, modifier, options) ->
    #console.log "[update(#{JSON.stringify query}, #{JSON.stringify modifier}, #{JSON.stringify options})]"
    doc = @findOne(query)
    #console.log "  << #{JSON.stringify doc}"
    if !doc? && options?.upsert
      #** assert query.key? and query.column? **#
      doc = {}
      for k, v of query then doc[k] = _.clone(v)
      @insert(doc)
    s = JSON.stringify
    for k, v0 of modifier
      if k == "$set"
        for k, v of v0
          doc[k] = _.clone(v)
      else if k == "$pull"
        for k, v of v0
          doc[k] = (x for x in doc[k] when !EJSON.equals(x, v))
      else if k == "$addToSet"
        for k, v of v0
          l = doc[k]
          if l.every((x) -> !EJSON.equals(x, v)) then l.push(v)
      else if k[0] == "$"
        throw Error "unimplemented [update(query=#{s query}, modifier=#{s modifier}, options=#{s options}) doc=#{s doc}]"
      else
        doc[k] = _.clone(v)
    #console.log "  >> #{JSON.stringify doc}"

  upsert: (query, modifier, options) ->
    if options? then throw Error "unimplemented upsert(..., options)"
    @update(query, modifier, {upsert: true})

  remove: (query) ->
    if (column = query.column)?
      byKey = @byColumn[column]
      if (key = query.key)?
        if (doc = byKey.get(key))?
          @stash(doc)
          byKey.delete(key)
      else
        if byKey?
          for k, doc of byKey.obj
            @stash(doc)
          delete @byColumn[column]
    else
      if (key = query.key)?
        for k, v of @byColumn
          @remove {column: k, key: key}
      else
        @byColumn = {}
        @byId = {}

  stash: (doc) ->
    #console.log "  stash[doc=#{JSON.stringify doc}]"
    delete @byId[doc._id]
    @recycle.set([doc.column, doc.key],  doc._id)

#
# Provides transaction-like behaviour by taking a snapshot of the
# Cells collection in memory, manipulating it and then storing the
# changes back to the Mongo collection.
#
class Transaction
  
  class @Cells
    
    constructor: (@dbCells) ->
      #@mem = new Mongo.Collection(null)
      @mem = new CellsInMemory
      
    prefetch: ->
      @mem.insert(doc) for doc in @dbCells.find().fetch()
        
    insert: (doc) ->
      doc = _.clone(doc)
      doc.dirty = true
      @mem.insert(doc)
      
    update: (query, values, upsert=false) ->
      if _.size(values) != 1
        throw new Exception("unsupported update in transaction: '#{EJSON.stringify values}'")
      if values.$set?
        values = _.clone(values)
        values.$set.dirty = true
      else if values.$pull? || values.$addToSet?
        values = _.clone(values)
        values.$set = {dirty: true}
      else
        throw new Exception("unsupported update in transaction: '#{EJSON.stringify values}'")
      if upsert
        @mem.upsert(query, values)
      else
        @mem.update(query, values)
        
    upsert: (query, values) ->
      @update(query, values, true)
      
    remove:  (query={})  ->  @mem.remove(query) # nothing fancy here...
    find:    (query={})  ->  @mem.find(query)
    findOne: (query={})  ->  @mem.findOne(query)
    
    commit: ->
      raw = @dbCells.rawCollection()
      @dbCells.find().forEach (doc) =>
        if ! @mem.findOne(doc._id)
          raw.remove({_id: doc._id}, (err) -> if err? then console.log "remove: #{err}")
          #@dbCells.remove(doc._id)
      @mem.find({dirty: true}).forEach (doc) =>
        delete doc.dirty
        raw.update({_id: doc._id}, doc, {upsert: true}, (err) -> if err? then console.log "remove: #{err}")
        #@dbCells.upsert(doc._id, doc)
    
  constructor: (dbCells) ->
    @Cells = new Transaction.Cells(dbCells ? Cells)
    
  begin: ->
    @Cells.prefetch()
    $$.Cells = @Cells
    
  rollback: ->
    $$.Cells = @Cells.dbCells
    undefined
    
  commit: ->
    @Cells.commit()
    $$.Cells = @Cells.dbCells
    undefined

        

exported {Tablespace, CellId, FamilyId, rootCell, allCellIdsInColumnIgnoreErrors, Transaction, CellsInMemory}
