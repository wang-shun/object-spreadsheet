# Future: Make this better.
standardServerCallback = (error, result) ->
  if error?
    alert('The operation failed on the server: ' + error.message)

andThen = (cont) ->
  (error, result) ->
    if error?
      standardServerCallback(arguments...)
    else
      cont(result)

# The Error constructor is not usable by subclasses
# (see https://github.com/jashkenas/coffeescript/issues/2359, unclear what our
# version of CoffeeScript is doing), but apparently we can throw any object we
# like, it just won't have a stack trace.
class NotReadyError
  constructor: (@what) ->

Router.route "/", -> @render "Spreadsheet"  # @deprecated (should show list of avail sheets)

Router.route "/:sheet", ->
  @render "Spreadsheet", data: {sheet: @params.sheet}
Router.route "/:sheet/views/:_id", ->
  @render "Spreadsheet", data: {sheet: @params.sheet, viewId: @params._id}
Router.route "/:sheet/schema", ->
  @render "Schema", data: {sheet: @param.sheet}

# Grid utilities

class ViewCell
  constructor: (@value = '', @rowspan = 1, @colspan = 1, @cssClasses = []) ->
    @qFamilyId = null
    @qCellId = null
    @columnId = null
    # Use in combination with columnId or qCellId to distinguish key and object
    # (bullet/chevron) columns in the UI.
    @isObject = false
    @kind = null
    @fullText = null

# Object that can be used as ViewCell.value or ViewHlist.value to defer the
# resolution of the target cell ID to a row number.  I'm a terrible person for
# taking advantage of heterogeneous fields in JavaScript... ~ Matt
class CellReference
  constructor: (@qCellId) ->

# Mutate "orig" by adding "extension" at the bottom.
# This would be a good place to add some assertions...
gridVertExtend = (orig, extension) ->
  orig.push(extension...)

# Mutate "orig" by adding "extension" at the right.
gridHorizExtend = (orig, extension) ->
  for i in [0...orig.length]
    orig[i].push(extension[i]...)

# Return a grid consisting of one "height x width" merged cell and enough dummy
# 1x1 cells.  You can mutate the upper-left cell as desired.
gridMergedCell = (height, width, value = '', cssClasses = []) ->
  grid =
    for i in [0...height]
      for j in [0...width]
        new ViewCell()
  grid[0][0].rowspan = height
  grid[0][0].colspan = width
  grid[0][0].value = value
  grid[0][0].cssClasses = cssClasses
  grid

gridCell = (grid, row, col) ->
  for i in [0..row]
    for j in [0..col]
      cell = grid[i][j]
      if i + cell.rowspan > row && j + cell.colspan > col
        return cell
  throw new Error("cell (#{row},#{col}) does not exist in grid")
  
gridBottomRow = (grid) ->
  if grid.length == 0
    []
  else
    i = grid.length - 1
    j = 0
    while j < grid[i].length
      cell = gridCell(grid, i, j)
      j += cell.colspan
      cell
  
class ViewVlist
  constructor: (@parentCellId, @minHeight, @hlists, @error) ->

class ViewHlist
  constructor: (@cellId, @minHeight, @value, @vlists, @cssClasses=[]) ->

colorIndexForDepth = (depth) -> depth % 6

class ViewSection

  constructor: (@layoutTree) ->
    @columnId = @layoutTree.root
    @col = getColumn(@columnId)
    # Typechecking should always fill in a type, even _error.
    unless @col? && @col.type?
      throw new NotReadyError("column #{@columnId}")
    # Future: Set this when we know it.
    @relationSingular = false
    # Future: Consider rendering _unit with isObject = true specially to save
    # space, e.g., a single column of hollow bullets.  We'd need to figure out
    # how to make this not confusing.
    @width = (@col.type != '_token') + @col.isObject
    @leftEdgeSingular = true
    @rightEdgeSingular = true
    # field index -> bool (have a separator column before this field)
    @haveSeparatorColBefore = []
    @subsections = []
    # @headerMinHeight refers to the expanded header.
    @headerMinHeight = @col.isObject + 2  # fieldName, type
    for sublayout, i in @layoutTree.subtrees
      subsection = new ViewSection(sublayout)
      @subsections.push(subsection)
      nextLeftEdgeSingular =
        subsection.relationSingular && subsection.leftEdgeSingular
      # TODO removed inner sep for now. Replace with dashed lines?
      haveSep = (@col._id == rootColumnId && i > 0) # (!@rightEdgeSingular && !nextLeftEdgeSingular)
      @haveSeparatorColBefore.push(haveSep)
      if haveSep
        @width++
      @width += subsection.width
      @headerMinHeight = Math.max(@headerMinHeight, 1 + subsection.headerMinHeight)
      @rightEdgeSingular =
        subsection.relationSingular && subsection.rightEdgeSingular
    @headerHeightBelow = @headerMinHeight - 1

  prerenderVlist: (parentCellId) ->
    ce = Cells.findOne({column: @columnId, key: parentCellId})
    if ce?.values?
      hlists =
        for value in ce.values
          @prerenderHlist(cellIdChild(parentCellId, value), value)
      minHeight = 0
      for hlist in hlists
        minHeight += hlist.minHeight
      # Don't add any extra rows: it's looking ridiculous.  Once we know which
      # columns are plural, we can reconsider adding extra rows.
      new ViewVlist(parentCellId, minHeight, hlists)
    else if ce?.error?
      new ViewVlist(parentCellId, 1, null, ce.error)
    else
      throw new NotReadyError("Cell #{@columnId}:#{JSON.stringify parentCellId}")

  prerenderHlist: (cellId, value) ->
    minHeight = 1
    # TODO: More type-specific rendering?
    displayValue =
      # Show _unit values for now so we can see if they aren't 'X'.
      #if @col.type == '_unit' then 'X'
      if !typeIsPrimitive(@col.type) then new CellReference({columnId: @col.type, cellId: value})
      # Should be OK if the user knows which columns are string-typed.
      else if typeof value == 'string' then value
      else if value.constructor == Date then value.toString("yyyy-MM-dd HH:mm")
      # Reasonable fallback
      else JSON.stringify(value)
    vlists =
      for subsection in @subsections
        subsection.prerenderVlist(cellId)
    minHeight = Math.max(1, (vlist.minHeight for vlist in vlists)...)
    new ViewHlist(cellId, minHeight, displayValue, vlists, @markDisplayClasses().concat(@valueDisplayClasses()))

  renderVlist: (vlist, height) ->
    qFamilyId = {columnId: @columnId, cellId: vlist.parentCellId}
    if vlist.hlists?
      grid = []
      for hlist in vlist.hlists
        gridVertExtend(grid, @renderHlist(hlist, hlist.minHeight))
      if grid.length < height
        if grid.length == 1
          # Make this row span 'height' rows
          for i in [1...height]
            grid.push(new ViewCell() for j in [0...@width])
          for cell in grid[0]
            cell.rowspan = height
        else
          # Add blank cell at bottom
          bottomGrid = gridMergedCell(height - grid.length, @width)
          bottomGrid[0][0].qFamilyId = qFamilyId
          gridVertExtend(grid, bottomGrid)
      for cell in gridBottomRow(grid)
        cell.cssClasses.push('vlast')
    else
      grid = gridMergedCell(height, @width, '!')
      grid[0][0].fullText = 'Error: ' + vlist.error
      grid[0][0].qFamilyId = qFamilyId
    grid

  markDisplayClasses: ->
    if @col.type == '_unit' then ['centered'] else []
      
  valueDisplayClasses: ->
    if @subsections.length == 0 then ['leaf'] else []

  # Only applicable if @col.isObject.
  objectSymbol: ->
    if @col._id == rootColumnId then ''
    else if @col.type == '_token' then '•' else '◦'

  renderHlist: (hlist, height) ->
    grid = ([] for i in [0...height])
    qCellId = {columnId: @columnId, cellId: hlist.cellId}
    # This logic could be in a ViewCell accessor instead, but for now it isn't
    # duplicated so there's no need.
    qFamilyId =
      if @columnId == rootColumnId
        null
      else
        {columnId: @columnId, cellId: cellIdParent(hlist.cellId)}
    if @col.isObject
      # Object
      gridObject = gridMergedCell(height, 1, @objectSymbol(), ['centered'])
      gridObject[0][0].qCellId = qCellId
      gridObject[0][0].qFamilyId = qFamilyId
      gridObject[0][0].isObject = true
      # For debugging and calling canned transactions from the console.
      gridObject[0][0].fullText = 'Object ID: ' + JSON.stringify(hlist.cellId)
      if @col.type != '_token'
        gridObject[0][0].cssClasses.push('rsKeyedObject')
      gridHorizExtend(grid, gridObject)
    if @col.type != '_token'
      # Value
      gridValue = gridMergedCell(height, 1, hlist.value, hlist.cssClasses)
      gridValue[0][0].qCellId = qCellId
      gridValue[0][0].qFamilyId = qFamilyId
      gridHorizExtend(grid, gridValue)
    # Subsections
    for subsection, i in @subsections
      if @haveSeparatorColBefore[i]
        gridHorizExtend(grid, gridMergedCell(height, 1))
      subsectionGrid = subsection.renderVlist(hlist.vlists[i], height)
      gridHorizExtend(grid, subsectionGrid)
    grid

  # As long as siblings are always separated by a separator, we can color just
  # based on depth.
  renderHeader: (expanded, depth) ->
    # Part that is always the same.
    myColorClass = 'rsHeaderColor' + colorIndexForDepth(if @col.isObject then depth else depth-1)
    grid = [[], []]  # c.f. renderHlist
    if @col.isObject
      fieldNameCell = new ViewCell(
        '', 1, 1,
        ['rsHeaderFieldNameObject',
         (if @col.type != '_token' then ['rsHeaderFieldNameKeyedObject'] else [])...,
         myColorClass])
      fieldNameCell.columnId = @columnId
      fieldNameCell.isObject = true
      typeCell = new ViewCell(
        @objectSymbol(), 1, 1,
        ['rsHeaderTypeObject',
         (if @col.type != '_token' then ['rsHeaderTypeKeyedObject'] else [])...,
         'centered', myColorClass])
      typeCell.columnId = @columnId
      typeCell.isObject = true
      if @col.type == '_token'
        # There is no value UI-column, so certain functionality that would
        # normally be on the value UI-column is on the object UI-column instead.
        fieldNameCell.kind = 'tokenObject-below'
        typeCell.kind = 'tokenObject-type'
        typeCell.fullText = 'Column ID ' + @columnId + ' (token)'
      else
        fieldNameCell.kind = 'keyedObject-below'
        typeCell.kind = 'keyedObject-type'
      gridHorizExtend(grid, [[fieldNameCell], [typeCell]])
    if @col.type != '_token'
      fieldNameCell = new ViewCell(
        @col.fieldName ? '', 1, 1, [
          (if @col.isObject then 'rsHeaderFieldNameKey' else 'rsHeaderFieldNameLeaf'),
          myColorClass])
      fieldNameCell.columnId = @columnId
      fieldNameCell.kind = 'below'
      typeName =
        if @col.type == '_unit' then 'X'
        else if typeIsPrimitive(@col.type) then @col.type
        else Columns.findOne(@col.type)?.objectName ? (""+@col.type)[...4]
      # XXX: The value in the cell is not consistent with what we allow the user
      # to type in the cell!
      typeCell = new ViewCell(
        (if @col.formula? then '=' else '') +
        (if @col.specifiedType? then typeName else "(#{typeName})") +
        (if @col.typecheckError? then '!' else ''),
        1, 1, [
          (if @col.isObject then 'rsHeaderTypeKey' else 'rsHeaderTypeLeaf'),
          myColorClass].concat(@markDisplayClasses()))
      typeCell.fullText = (
        'Column ID ' + @columnId + ': ' +
        'type ' + (@col.type ? '') + (if @col.specifiedType? then ' (specified)' else '') +
        (if @col.formula? then ' (formula)' else '') +
        (if @col.typecheckError? then "; typecheck error: #{@col.typecheckError}" else ''))
      typeCell.columnId = @columnId
      typeCell.kind = 'type'
      gridHorizExtend(grid, [[fieldNameCell], [typeCell]])

    unless @col.isObject
      return grid

    height = if expanded then @headerMinHeight else 3
    currentHeight = 2
    makeCorner = (isFinal) =>
      classes = ['rsHeaderCorner']
      unless isFinal
        classes.push('rsHeaderNonfinal')
      classes.push(myColorClass)
      corner = gridMergedCell(height - 2, grid[0].length,
                              @col.objectName ? '', classes)
      corner[0][0].columnId = @columnId
      corner[0][0].isObject = true
      corner[0][0].kind = 'top'
      gridVertExtend(corner, grid)
      grid = corner
      currentHeight = height

    for subsection, i in @subsections
      if @haveSeparatorColBefore[i]
        gridSeparator = gridMergedCell(currentHeight, 1, '', [myColorClass])
        gridHorizExtend(grid, gridSeparator)
      if currentHeight == 2 && subsection.headerMinHeight > 2
        makeCorner(false)
      subsectionGrid = subsection.renderHeader(expanded, depth+1)
      if subsectionGrid.length < currentHeight
        paddingGrid = gridMergedCell(
          currentHeight - subsectionGrid.length, subsection.width,
          '',
          [
            (if i < @subsections.length - 1 then ['rsHeaderNonfinal'] else [])...,
            myColorClass
          ])
        gridVertExtend(paddingGrid, subsectionGrid)
        subsectionGrid = paddingGrid
      gridHorizExtend(grid, subsectionGrid)
    if currentHeight == 2
      makeCorner(true)
    grid

# This may hold a reference to a ViewCell object from an old View.  Weird but
# shouldn't cause any problem and not worth doing differently.
selectedCell = null

fullTextToShow = new ReactiveVar(null)
isLoading = new ReactiveVar(true)

Template.formulaValueBar.helpers({
  loading: () -> isLoading.get()
  fullTextToShow: () -> fullTextToShow.get()
  addStateCellArgs: () -> addStateCellArgs.get()
  changeColumnArgs: () -> changeColumnArgs.get()
})

addStateCellArgs = new ReactiveVar([], EJSON.equals)
Template.addStateCell.events({
  'submit form': (event, template) ->
    try
      inputField = template.find('input[name=value]')
      valueStr = inputField?.value
      StateEdit.addCell @qFamilyId, valueStr,
      # Clear the field on successful submission (only)
      andThen -> if inputField? then inputField.value = ''
      false # prevent clear
    catch e
      console.log e.stack
      false
})

class StateEdit

  @parseValue: (qFamilyId, text) ->
    if !text? then return "-"  # placeholder. TODO use a special object as placeholder
    type = getColumn(qFamilyId.columnId).type
    if !typeIsPrimitive(type)
      if (m = /^@(\d+)$/.exec(text))
        wantRowNum = Number.parseInt(m[1])
        for [qCellId, coords] in view.qCellIdToGridCoords.entries()
          if qCellId.columnId == type && coords.dataRow == wantRowNum
            return qCellId.cellId
        throw new Error("Column #{type} contains no cell at row #{wantRowNum}.")
      else
        throw new Error('Malformed cell reference.')
    else if type == '_unit'
      'X'
    else if type == '_token'
      # XXX: Is this OK or do we want the server to generate the token?  For
      # unprivileged users, we probably want the server to generate it, but we
      # may not reuse this code for unprivileged users anyway.
      Random.id()
    else if type == '_string' || type == 'text'
      text
    else if type == 'date'
      Date.parse(text) || throw new Error("Invalid date, '#{text}'")
    else
      JSON.parse text

  @parseValueUi: (qFamilyId, text) ->
    try
      @parseValue qFamilyId, text
    catch e
      alert('Invalid value: ' + e.message)
      null

  @addCell: (qFamilyId, enteredValue, callback=->) ->
    key = qFamilyId.cellId
    if (newValue = @parseValueUi qFamilyId, enteredValue)?
      new ColumnBinRel(qFamilyId.columnId)
        .add key, newValue, callback

  @modifyCell: (qCellId, enteredValue, callback=->) ->
    key = cellIdParent(qCellId.cellId)
    if (newValue = @parseValueUi(
        {columnId: qCellId.columnId, cellId: key}, enteredValue))?
      # TODO check if cell has children!
      new ColumnBinRel(qCellId.columnId)
        .removeAdd qCellId.cellId, null, newValue, callback

  @removeCell: (qCellId, callback=->) ->
    # TODO check if cell has children!
    new ColumnBinRel(qCellId.columnId)
      .remove qCellId.cellId, null, callback

  @canEdit: (columnId) ->
    col = getColumn(columnId)
    # May as well not let the user try to edit _unit.
    col? && columnIsState(col) && col.type not in ['_token', '_unit']

#
# Template changeColumn
#

stringifyType = (type) ->
  if typeIsPrimitive(type) then type
  else
    c = getColumn(type)
    if c?
      objName = if c.parent then getColumn(c.parent).objectName else ""
      prefix = if objName? then "#{objName}:" else ""
      prefix + c.objectName
    else
      "?<#{type}>"
    
changeColumnArgs = new ReactiveVar([], EJSON.equals)
# We mainly care that this doesn't crash.
origFormulaStrForColumnId = (columnId) ->
  formula = getColumn(columnId)?.formula
  formula && stringifyFormula(getColumn(columnId).parent, formula)
newFormulaStr = new ReactiveVar(null)
Template.changeColumn.rendered = () ->
  orig = origFormulaStrForColumnId(Template.currentData().columnId)
  newFormulaStr.set(orig)
  # Handles case when showing only the "Create formula" button for a non-formula column.
  if orig
    @find('input[name=formula]').value = orig
Template.changeColumn.helpers
  columnName: ->
    c = getColumn(@columnId)
    objName = if c.parent then getColumn(c.parent).objectName else ""
    prefix = if objName? then "#{objName}:" else ""
    prefix + (c?.objectName ? c?.fieldName ? '<unnamed>')
  columnType: ->
    c = getColumn(@columnId)
    if c?.type then stringifyType(c.type) else ''
  columnSpecifiedType: ->
    c = getColumn(@columnId)
    if c?.specifiedType then stringifyType(c.specifiedType) else ''
  formula: ->
    origFormulaStrForColumnId(@columnId)
  formulaClass: ->
    if newFormulaStr.get() != origFormulaStrForColumnId(@columnId)
      'formulaModified'
    else
      ''
  contextText: ->
    col = getColumn(@columnId)
    if col.isObject
      objectNameWithFallback(getColumn(col.parent)) ? '<unnamed>'
    else null
  contextColorIndex: ->
    col = getColumn(@columnId)
    if col.isObject
      colorIndexForDepth(columnDepth(col.parent))
    else null

Template.changeColumn.events
  'input .formula': (event, template) ->
    newFormulaStr.set(template.find('input[name=formula]').value)
  'submit form': (event, template) ->
    # Set the type
    newVal = template.find('input[name=type]').value
    parsed = false
    try
      type = if newVal == '' then null else parseTypeStr(newVal)
      parsed = true
    catch e
      alert("Invalid type '#{newVal}'.")
      return false
    if parsed
      Meteor.call 'changeColumnSpecifiedType', $$, @columnId, type,
                  standardServerCallback
    # Set the formula
    formulaStr = newFormulaStr.get()
    if formulaStr?
      if formulaStr == ''
        formula = null   # remove formula
      else
        try
          formula = parseFormula(getColumn(@columnId).parent, formulaStr)
        catch e
          unless e instanceof FormulaValidationError
            throw e
          alert('Failed to parse formula: ' + e.message)
          return false
        # Canonicalize the string in the field, otherwise the field might stay
        # yellow after successful submission.
        formulaStr = stringifyFormula(getColumn(@columnId).parent, formula)
        template.find('input[name=formula]').value = formulaStr
        newFormulaStr.set(formulaStr)
      Meteor.call('changeColumnFormula', $$,
                  @columnId,
                  formula,
                  standardServerCallback)
    false # prevent refresh
  'click [type=reset]': (event, template) ->
    orig = origFormulaStrForColumnId(@columnId)
    newFormulaStr.set(orig)
    template.find('input[name=formula]').value = orig
    false # prevent clear
  'click .create': (event, template) ->
    # Default formula to get the new column created ASAP.
	# Then the user can edit it as desired.
    formula = DUMMY_FORMULA
    Meteor.call 'changeColumnFormula', $$, @columnId, formula,
                standardServerCallback
    # TODO warn user if column has data!!
  'keydown form': (event, template) ->
    if (event.which == 27) then template.find("[type=reset]")?.click()


insertBlankColumn = (parentId, index, view) ->
  # Obey the restriction on a state column as child of a formula column.
  # Although changeColumnFormula allows this to be bypassed anyway... :(
  formula = if getColumn(parentId).formula? then DUMMY_FORMULA else null
  Meteor.call('defineColumn', $$,
              parentId,
              index,
              null,  # fieldName
              null,  # specifiedType
              false, # isObject
              null,  # objectName
              formula,  # formula
              view?.id,
              standardServerCallback)


headerExpanded = new ReactiveVar(false)
@toggleHeaderExpanded = () ->
  headerExpanded.set(!headerExpanded.get())

class ClientView

  constructor: (@view) ->
    @options =
      showTypes: false         # Show type row in header
      headerExpandable: false  # Show '+' button on top left corner
      palette: 'boring'        # 'boring' for grey, 'rainbow' for dazzling colors
    @reload()
    @hot = null

  reload: () ->
    @layoutTree = @view?.def()?.layout || View.rootLayout()
    @mainSection = new ViewSection(@layoutTree)

  hotConfig: ->
    thisView = this
    # Display the root column for completeness.  However, it doesn't have a real
    # value.
    hlist = @mainSection.prerenderHlist([], '')
    grid = @mainSection.renderHeader(
      if headerExpanded.get() then @mainSection.headerMinHeight else null,
      0)
    for row in grid
      for cell in row
        cell.cssClasses.push('htBottom', 'rsHeader')  # easiest to do here
    headerHeight = grid.length
    if !@options.showTypes # HACK: Delete the last header row
      grid.pop()
      for row,i in grid
        for cell in row
          if cell.rowspan > grid.length - i
            cell.rowspan = grid.length - i
    gridData = @mainSection.renderHlist(hlist, hlist.minHeight)

    # Resolve cell cross-references.
    @qCellIdToGridCoords = new EJSONKeyedMap()
    for rowCells, i in gridData
      for cell, j in rowCells
        if cell.qCellId? && cell.isObject
          # dataRow is user-facing row number, one-based.
          # row/col: Account for header rows and caption column.  We could
          # compute these later but this is easier for now.
          @qCellIdToGridCoords.set(cell.qCellId, {row: headerHeight + i, col: j+1, dataRow: i+1})
    for row in gridData
      for cell in row
        if cell.value instanceof CellReference
          cell.referent = cell.value.qCellId
          cell.display = '@' + (@qCellIdToGridCoords.get(cell.value.qCellId)?.dataRow || '?')
    gridVertExtend(grid, gridData)

    gridCaption = []
    if @options.headerExpandable
      if headerHeight > 2
        # This is terrible but it will take ten times as long to do properly...
        # Fix the width so the columns don't move when '+' becomes '-' or vice versa.
        cnHtml = ("<button class='headerCollapse' onclick='toggleHeaderExpanded();'>" +
                  "#{if headerExpanded.get() then '-' else '+'}</button> Obj")
        gridVertExtend(gridCaption,
                       gridMergedCell(headerHeight - 2, 1, cnHtml, ['htBottom', 'rsCaption']))
      gridCaption.push(
        [new ViewCell('Field', 1, 1, ['rsCaption'])],
        [new ViewCell('Type', 1, 1, ['rsCaption'])])
    else
      gridVertExtend(gridCaption,
                     gridMergedCell(headerHeight - 1, 1, "", ['htBottom', 'rsCaption']))
      gridVertExtend(gridCaption,
                     gridMergedCell(1, 1, "", ['rsCaption']))
      
    if !@options.showTypes # HACK: Same
      gridCaption.pop()
      headerHeight = headerHeight - 1
    gridVertExtend(gridCaption,
                   ([new ViewCell(i+1, 1, 1, ['rsCaption','rsRowNum'])] for i in [0...gridData.length]))
    gridHorizExtend(gridCaption, grid)
    grid = gridCaption
    @grid = grid

    separatorColumns = (i for cell,i in grid[headerHeight - 1] when i != 0 && !cell.columnId)
    @separatorColumns = separatorColumns
    SEPCOL_WIDTH = 20

    d = {
      data: ((cell.display || cell.value for cell in row) for row in grid)
      # Future: Fixing the ancestors of the leftmost visible column would be
      # clever, though with carefully designed individual views, we may never
      # need it.  We may also want to fix the header for large data sets.
      fixedColumnsLeft: 1
      # Separator columns are 8 pixels wide.  Others use default width.
      colWidths: (for i in [0...@grid[0].length]  # no way grid can be empty
                    if i in separatorColumns then SEPCOL_WIDTH else undefined)
      rowHeights:
        # Specify all the row heights (23 pixels is the Handsontable default),
        # otherwise the fixed clone of the left column sometimes reduced the
        # objectName row to zero height because it wasn't constrained by the
        # content of the real table.  We can look out for any similar glitches.
        if headerExpanded.get()
          for i in [0...@grid.length]
            if i < headerHeight - 3 then 10 else 23
        else
          23 for i in [0...@grid.length]
      cells: (row, col, prop) =>
        cell = @grid[row]?[col]
        if !cell then return {}  # may occur if grid is changing
        adjcol = col+cell.colspan
        classes = if col in @separatorColumns then ['separator'] else
                  if adjcol in @separatorColumns then ['incomparable'] else []
        if cell.qCellId? && cell.isObject && (refc = @refId(cell.qCellId))?
          classes.push("ref-#{refc}")
        ancestors = if cell.qCellId? then new CellId(cell.qCellId).getAncestors()  \
                    else if cell.qFamilyId? then new FamilyId(cell.qFamilyId).getAncestors() \
                    else []
        for ancestor in ancestors
          if (refc = @refId(ancestor))?
            classes.push("parent-#{refc}")
        {
          renderer: if col == 0 then 'html' else 'text'
          className: (cell.cssClasses.concat(classes)).join(' ')
          # Only column header "top", "below", and "type" cells can be edited,
          # for the purpose of changing the objectName, fieldName, and specifiedType respectively.
          readOnly: !(cell.kind in ['top', 'below', 'type'] && cell.columnId != rootColumnId ||
                      cell.qCellId? && !cell.isObject && StateEdit.canEdit(cell.qCellId.columnId) ||
                      cell.qFamilyId? && !cell.isObject && StateEdit.canEdit(cell.qFamilyId.columnId))
        }
      autoColumnSize: true
      mergeCells: [].concat((
        for row,i in grid
          for cell,j in row when cell.rowspan != 1 || cell.colspan != 1
            {row: i, col: j, rowspan: cell.rowspan, colspan: cell.colspan}
        )...)

      # We don't have a principled design for how the selection should move
      # after pressing Enter, and for now, the default behavior is causing
      # surprises when it moves the selection to the padding cell at the bottom
      # of a family, which is mapped by the "select similar cell" code to the
      # first cell in the family.
      enterMoves: {row: 0, col: 0}

      # Seems more helpful to the user (e.g., when scrolling the browser window).
      # See if we have trouble with the user needing to "escape" from the table.
      outsideClickDeselects: false

      afterDeselect: () ->
        thisView.onSelection()

      afterSelection: (r1, c1, r2, c2) ->
        thisView.onSelection()
        
      beforeKeyDown: (event) ->
        thisView.onKeyDown(event)

      beforeChange: (changes, source) =>
        for [row, col, oldVal, newVal] in changes
          cell = @grid[row][col]
          # One of these cases should apply...
          if cell.kind == 'top'
            name = if newVal == '' then null else newVal
            Meteor.call 'changeColumnObjectName', $$, cell.columnId, name,
                        standardServerCallback
          if cell.kind == 'below'
            name = if newVal == '' then null else newVal
            Meteor.call 'changeColumnFieldName', $$, cell.columnId, name,
                        standardServerCallback
          if cell.kind == 'type'
            parsed = false
            try
              type = if newVal == '' then null else parseTypeStr(newVal)
              parsed = true
            catch e
              alert('Invalid type.')
            if parsed
              Meteor.call 'changeColumnSpecifiedType', $$, cell.columnId, type,
                          standardServerCallback
          if cell.qCellId? && !cell.isObject
            if newVal
              StateEdit.modifyCell cell.qCellId, newVal
            else
              StateEdit.removeCell cell.qCellId
          else if cell.qFamilyId? && !cell.isObject
            if newVal
              StateEdit.addCell cell.qFamilyId, newVal
        # Don't apply the changes directly; let them come though the Meteor
        # stubs.  This ensures that they get reverted by Meteor if the server
        # call fails.
        return false

      contextMenu: {
        items: {
          # Future: Would be nice to move selection appropriately on column
          # insert/delete, but this is a less common case.

          addObjectType: {
            name: 'Make into object'
            disabled: () =>
              c = @getSingleSelectedCell()
              !((ci = c?.columnId)? && ci != rootColumnId &&
                !(col = getColumn(ci)).isObject)
            callback: () =>
              c = @getSingleSelectedCell()
              ci = c.columnId
              Meteor.call('changeColumnIsObject', $$, ci, true,
                          standardServerCallback)
          }
          removeObjectType: {
            name: 'Make into value'
            disabled: () =>
              c = @getSingleSelectedCell()
              !((ci = c?.columnId)? && ci != rootColumnId &&
                (col = getColumn(ci)).isObject &&
                (col.children.length == (if col.type == '_token' then 1 else 0)))
            callback: () =>
              c = @getSingleSelectedCell()
              ci = c.columnId
              Meteor.call('changeColumnIsObject', $$, ci, false,
                          standardServerCallback)
          }

          addChildLast: {
            name: 'Add child column'
            disabled: () =>
              c = @getSingleSelectedCell()
              !(c?.columnId)?
              #!((ci = c?.columnId)? && c.kind == 'top' &&
              #  (col = getColumn(ci)).isObject && col.type == '_token')
            callback: () =>
              c = @getSingleSelectedCell()
              ci = c.columnId
              col = getColumn(ci)
              index = col.children.length
              #@hot.deselectCell()
              insertBlankColumn ci, index, @view
          }
          deleteColumn: {
            name: 'Delete column'
            disabled: () =>
              c = @getSingleSelectedCell()
              # Future: Support recursive delete.
              !((ci = c?.columnId)? && ci != rootColumnId &&
                (col = getColumn(ci)).children.length == 0 &&
                # A keyed object with no (non-key) children spans two UI
                # columns.  It might be surprising if "Delete column" on a
                # header cell in one of the two UI columns deleted the entire
                # thing.  But "Delete column" on the top cell (which spans both
                # columns) is OK.
                (!col.isObject || col.type == '_token' || c.kind == 'top'))
            callback: () =>
              c = @getSingleSelectedCell()
              ci = c.columnId
              @hot.deselectCell() # <- Otherwise changeColumn form gets hosed.
              Meteor.call('deleteColumn', $$, ci,
                          standardServerCallback)
          }
          sep1: '----------'
          jumpToReferent: {
            name: 'Jump to referent'
            # Future: There should be some way to take advantage of this feature
            # without needing the referent to be in the same view as the
            # selected cell.
            disabled: () =>
              c = @getSingleSelectedCell()
              !(c?.referent? && @qCellIdToGridCoords.get(c.referent)?)
            callback: () =>
              c = @getSingleSelectedCell()
              coords = @qCellIdToGridCoords.get(c.referent)
              @hot.selectCell(coords.row, coords.col, coords.row, coords.col)
          }
          deleteStateCell: {
            name: 'Delete cell'
            disabled: () =>
              # XXX: For keyed objects, one could argue it's more consistent to
              # allow this only on the key.
              c = @getSingleSelectedCell()
              !(c? && c.qCellId? &&
                columnIsState(getColumn(c.qCellId.columnId)))
            callback: () =>
              c = @getSingleSelectedCell()
              if c.qCellId?
                StateEdit.removeCell c.qCellId, standardServerCallback
          }
        }
      }
    }
    d

  hotCreate: (domElement) ->
    @hot = new Handsontable(domElement, @hotConfig())
    $(domElement).addClass("pal-#{@options.palette}")
    if @options.showTypes then $(domElement).addClass('showTypes')
    # Monkey patch: Don't let the user merge or unmerge cells.
    @hot.mergeCells.mergeOrUnmergeSelection = (cellRange) ->
    @hot

  hotReconfig: (hot) ->
    d = @hotConfig()
    ## Crazy hack!
    @hot = hot = hot ? @hot
    MergeCells = hot.mergeCells.constructor
    hot.mergeCells = new MergeCells(d.mergeCells)
    hot.mergeCells.mergeOrUnmergeSelection = (cellRange) ->
    hot.updateSettings {colWidths: d.colWidths, rowHeights: d.rowHeights}
    hot.loadData d.data
    #hot.render()

  getSingleSelectedCell: =>
    s = @hot.getSelected()
    unless s?
      # Unsure under what circumstances this can happen.  Whatever.
      return null
    [r1, c1, r2, c2] = s
    [r1, r2] = [Math.min(r1, r2), Math.max(r1, r2)]
    [c1, c2] = [Math.min(c1, c2), Math.max(c1, c2)]
    cell = @grid[r1][c1]
    if r2 == r1 + cell.rowspan - 1 && c2 == c1 + cell.colspan - 1
      return cell
    else
      return null

  refId: (qCellId) ->
    loc = @qCellIdToGridCoords.get(qCellId)
    if loc?
      "#{loc.row}-#{loc.col}"

  highlightReferent: (referent) ->
    $(".referent").removeClass("referent")
    if referent? && (refc = @refId(referent))?
      $(".ref-#{refc}").addClass("referent")

  highlightObject: (obj) ->
    $(".selected-object").removeClass("selected-object")
    if obj? && (refc = @refId(obj))?
      $(".parent-#{refc}").addClass("selected-object")
        
  onSelection: ->
    selectedCell = @getSingleSelectedCell()
    fullTextToShow.set(selectedCell?.fullText)
    @highlightReferent(selectedCell?.referent)
    @highlightObject(selectedCell?.qCellId)
    # _id: Hacks to get the #each to clear the forms when the cell changes.
    addStateCellArgs.set(
      if (qf = selectedCell?.qFamilyId)? && columnIsState(col = getColumn(qf.columnId))
        [{
          _id: EJSON.stringify(qf)
          qFamilyId: qf
          canAddValue: col.type not in ['_token', '_unit'] && !selectedCell.isObject
          # A token column has only the object UI-column, though we don't set
          # isObject on family padding cells.  So don't check it.
          canAddToken: col.type == '_token'
          # Adding a duplicate value has no effect, but disallow it as a
          # hint to the user.  !selectedCell.isObject is in principle a
          # requirement, though it ends up being redundant because the only way
          # to select an object cell is to already have a unit value present.
          canAddUnit: (col.type == '_unit' && !selectedCell.isObject &&
                       !Cells.findOne({column: qf.columnId, key: qf.cellId})?.values?.length)
        }]
      else
        []
    )
    changeColumnArgs.set(
      if selectedCell? &&
         (ci = selectedCell.columnId)? && ci != rootColumnId
        [{_id: ci, columnId: ci}]
      else
        []
    )

  onKeyDown: (event) ->
    Handsontable.Dom.enableImmediatePropagation(event)
    if event.altKey && event.metaKey
      event.stopImmediatePropagation()
    else if !event.altKey && !event.ctrlKey && !event.metaKey 
      if event.which == 13    # Enter
        selectedCell = @getSingleSelectedCell()
        if (qf = selectedCell?.qFamilyId)? && columnIsState(col = getColumn(qf.columnId))
          if col.type == '_token'
            StateEdit.addCell qf, '*'
      else if event.which == 46    # Delete
        selectedCell = @getSingleSelectedCell()
        if (qc = selectedCell?.qCellId)? && columnIsState(col = getColumn(qc.columnId))
          if col.type == '_token'
            StateEdit.removeCell qc
    else if event.ctrlKey && !event.altKey && !event.metaKey
      if event.which == 13    # Enter
        selectedCell = @getSingleSelectedCell()
        if (qf = selectedCell?.qFamilyId)? && columnIsState(col = getColumn(qf.columnId))
          StateEdit.addCell qf, undefined   # insert placeholder
          event.stopImmediatePropagation()
    else if event.altKey && !event.ctrlKey && !event.metaKey
      # Use Alt + Left/Right to reorder columns inside parent
      #     Alt + Up/Down to make column into object/value
      if event.which == 37 || event.which == 39 || event.which == 38 || event.which == 40
        event.stopImmediatePropagation()
        event.stopPropagation()
        event.preventDefault()
        selectedCell = @getSingleSelectedCell()
        if selectedCell? && (ci = selectedCell.columnId)? && 
            (col = getColumn(ci))? && col.parent? && (parentCol = getColumn(col.parent))
          n = parentCol.children.length
          index = parentCol.children.indexOf(ci)
          if event.which == 37 && index > 0                # Left
            $$.call 'reorderColumn', ci, index-1
          else if event.which == 39 && index < n - 1       # Right
            $$.call 'reorderColumn', ci, index+1
          else if event.which == 38 && !col.isObject       # Up
            $$.call 'changeColumnIsObject', ci, true
          else if event.which == 40 && col.isObject        # Down
            $$.call 'changeColumnIsObject', ci, false
          
  
  selectSingleCell: (r1, c1) ->
    cell = @grid[r1][c1]
    @hot.selectCell(r1, c1, r1 + cell.rowspan - 1, c1 + cell.colspan - 1)

  selectMatchingCell: (predicate) ->
    for i in [0...@grid.length]
      for j in [0...@grid[i].length]
        if predicate(@grid[i][j])
          @selectSingleCell(i, j)
          return true
    return false


view = null


rebuildView = (viewId) ->
  if !view || !view.hot
    if view?.hot?
      view.hot.destroy()
    view = new ClientView(new View(viewId))
    view.hotCreate $('#View')[0]
  else
    view.reload() #viewDef
    view.hotReconfig()
  exported {view}  # for debugging
  # Try to select a cell similar to the one previously selected.
  if selectedCell?
    ((selectedCell.qCellId? &&
      view.selectMatchingCell((c) -> EJSON.equals(selectedCell.qCellId, c.qCellId) &&
                                     selectedCell.isObject == c.isObject)) ||
     (selectedCell.qFamilyId? &&
      view.selectMatchingCell((c) -> EJSON.equals(selectedCell.qFamilyId, c.qFamilyId))) ||
     (selectedCell.qFamilyId? &&
      view.selectMatchingCell((c) -> c.kind in ['below', 'tokenObject-below'] &&
                                     EJSON.equals(selectedCell.qFamilyId.columnId, c.columnId))) ||
     (selectedCell.kind? &&
      view.selectMatchingCell((c) -> selectedCell.kind == c.kind &&
                                     selectedCell.columnId == c.columnId)) ||
     false)
  # Make sure various things are consistent with change in table data or
  # selection (view.selectMatchingCell doesn't seem to trigger this).
  view.onSelection()
  isLoading.set(false)

# Helper decorator for use with Tracker.autorun
guarded = (op) ->
  ->
    try
      op arguments...
    catch e
      if e instanceof NotReadyError
        window.why = e
        return  # Let the autorun run again once we have the data.
      throw e


Template.Spreadsheet.rendered = ->
  sheet = @data?.sheet || ''
  viewId = @data?.viewId
  # $('body').addClass("present")   # uncomment for presentation mode (read from query string?)
  if sheet then document.title = sheet
  Relsheets.open(sheet)
  Tracker.autorun(guarded -> rebuildView viewId)


$ ->
  exported {ClientView, rebuildView, StateEdit}
