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

viewHOT = null

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
  # Load order...
  @FamilyData = new Mongo.Collection(FAMILY_DATA_COLLECTION)

  Tracker.autorun(rebuildView)
