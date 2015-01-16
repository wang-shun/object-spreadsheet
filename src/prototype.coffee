###
class FieldInfo

  constructor: (@name, @type, @singular, @unique) ->


class Table extends Array

  constructor: (@type, @fieldInfos, iterable) ->
    @push x for x in iterable
    p = {}
    for x in @fieldInfos
      do (x) -> p[x.name] = {get: -> @proj x.name}
    Object.defineProperties @, p

  colidx: (colname) ->
    (idx for fi,idx in @fieldInfos when fi.name == colname)[0]

  proj: (colname) ->
    idx = @colidx colname
    new BinRel(([i,row[idx]] for row,i in @ when row[idx] != null),
               @type, @fieldInfos[idx].type,
               @fieldInfos[idx].singular, @fieldInfos[idx].unique)

  cross: (that) ->
    pairs = [].concat([x,y] for x in @domain() for y in that.domain()...)
    new BinRel pairs, @type, that.type, false, false

  domain: -> i for _,i in @
  id: -> new BinRel(([i,i] for _,i in @), @type, @type, true, true)
###

class RSRel extends Array

  # Now the iterable should return [parentCellId, [value, childCellId]].
  ## "Singular" means the schema requires that for each x,
  ## there's at most one y such that (x,y) is in the relation.
  ## "Unique": other way around.  Better terms welcomed.
  constructor: (iterable
                #, @leftType, @rightType, @singular, @unique
  ) ->
    @push x for x in iterable

  # TODO: Implement something like this again when ready.
  #xpose: -> new BinRel([y,x] for [x,y] in @,
  #  @rightType, @leftType, @unique, @singular)

  lookup: (key) ->
    r[1] for r in @ when r[0] == key


class ViewField
  constructor: (@relation, @subsection) ->


class ViewSection

  constructor: (firstColumnName, @firstColumnType, @fields) ->
    # Currently, we always have the original value in the first column.
    @columnNames = [firstColumnName]
    @leftEdgeSingular = true
    @rightEdgeSingular = true
    # field index -> bool (have a separator column before this field)
    @haveSeparatorColBefore = []
    for field in @fields
      nextLeftEdgeSingular =
        field.relation.singular && field.subsection.leftEdgeSingular
      haveSep = (!@rightEdgeSingular && !nextLeftEdgeSingular)
      @haveSeparatorColBefore.push(haveSep)
      if haveSep
        @columnNames.push('')
      # TODO: Make the hierarchy clear in the column names?
      @columnNames.push(field.subsection.columnNames...)
      @rightEdgeSingular =
        field.relation.singular && field.subsection.rightEdgeSingular

  prerenderVlist: (values) ->
    hlists = (@prerenderHlist(value) for value in values)
    minHeight = 0
    for hlist in hlists
      minHeight += hlist.minHeight
    new ViewVlist(minHeight, hlists)

  prerenderHlist: (value) ->
    minHeight = 1
    items = []
    for field in @fields
      fieldValues = field.relation.lookup(value[1])
      if field.relation.singular
        item = field.subsection.prerenderHlist(fieldValues[0])
        minHeight = Math.max(minHeight, item.minHeight)
      else
        item = field.subsection.prerenderVlist(fieldValues)
        # Disable this behavior until we know which fields are singular again.
        ## Ensure that a plural field with only one value is followed by at least
        ## one blank row so the user can tell it is plural.  We currently don't
        ## provide a visual distinction between empty singular and plural fields.
        #minHeight = Math.max(minHeight,
        #                     item.minHeight + (fieldValues.length == 1))
        minHeight = Math.max(minHeight, item.minHeight)
      items.push(item)
    # TODO: More type-specific rendering?
    displayValue =
      # For now, we need to see token values in order to interpret IDs.
      # Future: Enable this again when we have a better way of rendering IDs.
      #if @firstColumnType == '_token' then '*'
      if @firstColumnType == '_unit' then 'X'
      # Should be OK if the user knows which columns are string-typed.
      else if typeof value[0] == 'string' then value[0]
      # Make sure IDs (especially) are unambiguous.
      else EJSON.stringify(value[0])
    new ViewHlist(minHeight, displayValue, items)

  renderVlist: (vlist, height) ->
    grid = []
    for hlist in vlist.hlists
      grid.push(@renderHlist(hlist, hlist.minHeight)...)
    # Add blank cell at bottom
    origHeight = grid.length
    for row in [origHeight..height-1] by 1
      grid.push(new ViewCell('', 1, 1) for col in [0..@columnNames.length-1] by 1)
    if origHeight < height
      grid[origHeight][0].rowspan = height - origHeight
      grid[origHeight][0].colspan = @columnNames.length
    grid

  renderHlist: (hlist, height) ->
    # Value
    grid = [].concat(
      [[new ViewCell(hlist.value, height, 1)]],
      [new ViewCell('', 1, 1)] for row in [1..height-1] by 1
    )
    # Fields
    for field, i in @fields
      if @haveSeparatorColBefore[i]
        grid[0].push(new ViewCell('', height, 1))
        for j in [1..height-1] by 1
          grid[j].push(new ViewCell('', 1, 1))
      fieldGrid =
        if field.relation.singular
        then field.subsection.renderHlist(hlist.items[i], height)
        else field.subsection.renderVlist(hlist.items[i], height)
      for j in [0..height-1] by 1
        grid[j].push(fieldGrid[j]...)
    grid

class ViewCell
  constructor: (@value, @rowspan, @colspan) ->

class ViewVlist
  constructor: (@minHeight, @hlists) ->

class ViewHlist
  # Items contains one item for each field: an hlist for a singular field or a
  # vlist for a plural field.
  constructor: (@minHeight, @value, @items) ->

class View
  constructor: (@domain, @mainSection) ->

  permuteColumns: (grid, header, colPerm) -> [
    ((row[i] for i in colPerm) for row in grid)
    (header[i] for i in colPerm)
  ]

  hotConfig: ->
    vlist = @mainSection.prerenderVlist(@domain)
    grid = @mainSection.renderVlist(vlist, vlist.minHeight)
    header = @mainSection.columnNames
    # TODO allow custom column permutations
    colPerm = (i for _,i in header)[1..]
    [grid, header] = @permuteColumns grid, header, colPerm
    d = {
      readOnly: true
      data: ((cell.value for cell in row) for row in grid)
      colHeaders: header
      # Separator columns are 8 pixels wide.  Others use default width.
      colWidths: (for n in header
                    if n then undefined else 8)
      afterGetColHeader: (col, TH) =>
        if header[col+1] == ''
          ($ TH) .addClass 'incomparable'
      columns: (for n in header
                  if n then {} else {className: 'incomparable'})\
               [1..] .concat [{}]
      autoColumnSize: true
      mergeCells: [].concat((
        for row,i in grid
          for cell,j in row when cell.rowspan != 1 || cell.colspan != 1
            {row: i, col: j, rowspan: cell.rowspan, colspan: cell.colspan}
        )...)
    }
    d

###
class TypeInfo
  constructor: ->
    # list to be set later for object types; will remain null for primitive types
    @domain = null
    # dict (name -> BinRel)
    @relations = {}

class Dataset
  constructor: ->
    # type name (string) -> TypeInfo
    # By convention, primitive types are lowercase ('string', 'bool', 'int',
    # 'real', 'datetime', whatever seems appropriate) and object types are
    # capitalized.
    @typeInfos = {}

  createTypeIfNecessary: (type) ->
    @typeInfos[type] ?= new TypeInfo()

  addForwardRelation: (name, relation) ->
    @createTypeIfNecessary(relation.leftType)
    # Assert no collision?
    @typeInfos[relation.leftType].relations[name] = relation

  addTable: (table) ->
    @createTypeIfNecessary(table.type)
    # Assert not already set?
    @typeInfos[table.type].domain = table.domain()
    for fieldInfo in table.fieldInfos
      relation = table.proj(fieldInfo.name)
      relationName = "#{table.type}:#{fieldInfo.name}"
      @addForwardRelation(relationName, relation)
      xpose = relation.xpose()
      xposeName = "~#{relationName}"
      @addForwardRelation(xposeName, xpose)

tables = [
  # TODO: Add subclasses of Person (Student, Teacher, Parent).
  new Table 'Person', [
    new FieldInfo("name", "string", true, true)
    new FieldInfo("parent", "Person", true, false)
  ], [
    ["Daniel Jackson", null]
    ["Jonathan Edwards", null]
    ["Matt McCutchen", 5]
    ["Michael McCutchen", 5]
    ["Shachar Itzhaky", 6]
    ["Rosemary McCutchen", null]
    ["Yoram Itzhaky", null]
  ]

  new Table 'Class', [
    new FieldInfo("code", "string", true, true)
    new FieldInfo("name", "string", true, true)
  ], [
    ['6.170', 'Software Studio']
    ['6.*+~', 'Alloy']
    ['6.:::', 'Managed Time']
  ]

  # Since this level of indirection would exist in a real application and helps to
  # exercise our support for hierarchy, we include it.  A real application would
  # add "term" and "meeting time" fields among others, but these are not currently
  # an important part of our demonstration.
  new Table 'Section', [
    new FieldInfo("class", "Class", true, false)
    new FieldInfo("teacher", "Person", true, false)
  ], [
    [0, 0]
    [1, 0]
    [2, 1]
  ]

  new Table 'Enrollment', [
    new FieldInfo("student", "Person", true, false)
    new FieldInfo("section", "Section", true, false)
  ], [
    [2, 2]
    [2, 0]
    [2, 1]
    [3, 0]
    [4, 1]
  ]

  # TODO: Uniqueness constraint on (teacher, time) pair
  new Table 'Slot', [
    new FieldInfo("teacher", "Person", true, false)
    new FieldInfo("time", "datetime", true, false)
  ], [
    [0, '2014-12-16 13:00']
    [0, '2014-12-16 13:15']
    [0, '2014-12-16 13:30']
    [0, '2014-12-16 13:45']
    [1, '2014-12-16 13:00']
    [1, '2014-12-16 14:00']
  ]

  # TODO: Constraint enrollment.section.teacher == slot.teacher
  new Table 'Meeting', [
    new FieldInfo("enrollment", "Enrollment", true, true)
    new FieldInfo("slot", "Slot", true, true)
  ], [
    [0, 4]
    [1, 1]
    [2, 2]
    [3, 3]
    [4, 0]
  ]
]


dataset = new Dataset()
for table in tables
  dataset.addTable(table)

# Add a dummy table "Unit" with a full relation to every other table
Unit = new Table 'Unit', [], [[]]
dataset.addTable Unit
for table in tables
  dataset.addForwardRelation(table.type, Unit.cross table)

# This lets the user navigate to any of the other tables :)
startType = 'Unit'

defaultSelections = {
  'Person': {
    'Person:name': {}
    '~Section:teacher': {
      'Section:class': {
        'Class:code': {}
        'Class:name': {}
      }
      '~Enrollment:section': {
        'Enrollment:student': {
          'Person:name': {}
        }
        '~Meeting:enrollment': {
          'Meeting:slot': {
            'Slot:time': {}
          }
        }
      }
    }
  }
}
###

# Above this point: model and some rendering-related code but no references to UI elements
# Below this point: UI code.

if Meteor.isClient

  ###
  viewDefTree = null

  vdtRoot = () -> viewDefTree.get_node('#')
  vdtChildren = (node) ->
    viewDefTree.get_node(child_id) for child_id in node.children
  ###

  viewHOT = null

  ###
  generateViewSection = (type, firstColumnName, node) ->
    new ViewSection(
      firstColumnName,
      for child in vdtChildren(node) when child.state.selected
        new ViewField(dataset.typeInfos[type].relations[child.original.user_relationName],
                      generateViewSection(child.original.user_type,
                                          child.original.user_relationName, child))
    )

  rebuildView = () ->
    if viewHOT
      viewHOT.destroy()
    viewDef = new View(dataset.typeInfos[startType].domain,
                       generateViewSection(startType, startType, vdtRoot()))
    viewHOT = new Handsontable($('#View')[0], viewDef.hotConfig())
    window.viewHOT = viewHOT  # debug

  # Asynchronous!  If we wanted to rebuildView once at the end, we'd need to
  # learn how to trigger it once all the callbacks are done.  For now we'll just
  # leave this looking goofy.
  applySelections = (node, selData) ->
    viewDefTree.load_node(node, () ->
      node = viewDefTree.get_node(node.id)  # loading invalidates references
      for child in vdtChildren(node)
        childSelData = selData[child.original.user_relationName]
        # changed.jstree is suppressed; caller is expected to rebuildView once.
        if childSelData
          viewDefTree.select_node(child)
          applySelections(child, childSelData)
        else
          viewDefTree.deselect_node(child)  # Removes descendants
    )
  ###

  @FamilyData = new Mongo.Collection(FAMILY_DATA_COLLECTION)

  # The Error constructor is not usable by subclasses
  # (see https://github.com/jashkenas/coffeescript/issues/2359, unclear what our
  # version of CoffeeScript is doing), but apparently we can throw any object we
  # like, it just won't have a stack trace.
  class NotReadyError

  # CLEANUP: Change the rendering code to read the published data directly
  # rather than generating RSRels as an intermediate step.
  generateViewSection = (columnId, type, allCellIds) ->
    column = Columns.findOne(columnId)  # published data
    unless column?
      throw new NotReadyError()
    new ViewSection(
      column.name ? column.cellName ? '',
      type,
      for childColumnId in column.children
        rel = []
        allChildCellIds = []
        childType = null
        for cellId in allCellIds
          # See if reactive.
          familyData = FamilyData.findOne(EJSON.stringify({columnId: childColumnId, cellId: cellId}))
          unless familyData?
            throw new NotReadyError()
          if familyData.state == FAMILY_SUCCESS
            # XXX: Model should assert that all families evaluate to the same type.
            childType ?= familyData.content.type
            for value in familyData.content.elements
              childCellId = cellIdChild(cellId, value)
              allChildCellIds.push(childCellId)
              rel.push([EJSON.stringify(cellId), [value, EJSON.stringify(childCellId)]])
          else
            # Hack: child cell ID 'null' will not relate to anything.
            rel.push([EJSON.stringify(cellId), ['ERROR', null]])
        new ViewField(new RSRel(rel), generateViewSection(childColumnId, childType, allChildCellIds))
    )

  rebuildView = () ->
    if viewHOT
      viewHOT.destroy()
      viewHOT = null
    try
      viewDef = new View([[null, EJSON.stringify([])]],
                         generateViewSection(rootColumnId, null, [rootCellId]))
    catch e
      if e instanceof NotReadyError
        return  # Let the autorun run again once we have the data.
      throw e
    viewHOT = new Handsontable($('#View')[0], viewDef.hotConfig())

  Meteor.startup () ->
    ###
    viewDefTreeHost = $('#ViewDefTree')
    viewDefTreeHost.jstree({
      plugins: ['checkbox']
      core: {
        data: (node, cb) ->
          childrenData =
            if node.id != '#' && !node.state.selected
              []
            else
              type = if node.id == '#' then startType else node.original.user_type
              for name, relation of dataset.typeInfos[type].relations
                {
                  user_relationName: name
                  user_type: relation.rightType
                  text: "#{name} (#{relation.rightType})"
                }
          cb.call(this, childrenData)
      }
      checkbox: {
        three_state: false
      }
    }).on('select_node.jstree', (e, data) ->
      viewDefTree.refresh_node(data.node)
    ).on('deselect_node.jstree', (e, data) ->
      viewDefTree.refresh_node(data.node)
    ).on('changed.jstree', (e) ->
      rebuildView()
    )
    viewDefTree = viewDefTreeHost.jstree()  # Weird API in Matt's opinion
    window.viewDefTree = viewDefTree
    rebuildView()
    applySelections(vdtRoot(), defaultSelections)
    ###
    Tracker.autorun(rebuildView)
