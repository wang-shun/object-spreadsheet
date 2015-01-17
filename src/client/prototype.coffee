# Future: Make this better.
standardServerCallback = (error, result) ->
  if error?
    alert('The operation failed on the server: ' + error.message)

# The Error constructor is not usable by subclasses
# (see https://github.com/jashkenas/coffeescript/issues/2359, unclear what our
# version of CoffeeScript is doing), but apparently we can throw any object we
# like, it just won't have a stack trace.
class NotReadyError

# Grid utilities

class ViewCell
  constructor: (@value = '', @rowspan = 1, @colspan = 1, @cssClasses = []) ->
    @qFamilyId = null
    @qCellId = null
    @columnIdTop = null
    @columnIdBelow = null

# Mutate "orig" by adding "extension" at the bottom.
# This would be a good place to add some assertions...
gridVertExtend = (orig, extension) ->
  orig.push(extension...)

# Mutate "orig" by adding "extension" at the right.
gridHorizExtend = (orig, extension) ->
  for i in [0..orig.length-1] by 1
    orig[i].push(extension[i]...)

# Return a grid consisting of one "height x width" merged cell and enough dummy
# 1x1 cells.  You can mutate the upper-left cell as desired.
gridMergedCell = (height, width, value = '', cssClasses = []) ->
  grid =
    for i in [0..height-1] by 1
      for j in [0..width-1] by 1
        new ViewCell()
  grid[0][0].rowspan = height
  grid[0][0].colspan = width
  grid[0][0].value = value
  grid[0][0].cssClasses = cssClasses
  grid

class ViewVlist
  # @hlists == null means error.
  constructor: (@parentCellId, @minHeight, @hlists) ->

class ViewHlist
  constructor: (@cellId, @minHeight, @value, @vlists) ->

class ViewSection

  constructor: (@columnId) ->
    @col = Columns.findOne(@columnId)
    unless @col?
      throw new NotReadyError()
    # Future: Set this when we know it.
    @relationSingular = false
    # Might be undefined (root cell or no cells), fail gently.
    @type =
      if @col.formula? then FormulaColumnType.findOne(@columnId)?.type
      else @col.type
    @width = 1
    @leftEdgeSingular = true
    @rightEdgeSingular = true
    # field index -> bool (have a separator column before this field)
    @haveSeparatorColBefore = []
    @subsections = []
    @headerHeightBelow = 3  # name, id, type
    for childColumnId in @col.children
      subsection = new ViewSection(childColumnId)
      @subsections.push(subsection)
      nextLeftEdgeSingular =
        subsection.relationSingular && subsection.leftEdgeSingular
      haveSep = (!@rightEdgeSingular && !nextLeftEdgeSingular)
      @haveSeparatorColBefore.push(haveSep)
      if haveSep
        @width++
      @width += subsection.width
      @headerHeightBelow = Math.max(@headerHeightBelow, subsection.headerMinHeight)
      @rightEdgeSingular =
        subsection.relationSingular && subsection.rightEdgeSingular
    @headerMinHeight = 1 + @headerHeightBelow  # cellName

  prerenderVlist: (parentCellId) ->
    familyData = FamilyData.findOne(EJSON.stringify({columnId: @columnId, cellId: parentCellId}))
    unless familyData?
      throw new NotReadyError()
    if familyData.state == FAMILY_SUCCESS
      hlists = (@prerenderHlist(parentCellId, value) for value in familyData.content.elements)
      minHeight = 0
      for hlist in hlists
        minHeight += hlist.minHeight
      # Don't add any extra rows: it's looking ridiculous.  Once we know which
      # columns are plural, we can reconsider adding extra rows.
      new ViewVlist(parentCellId, minHeight, hlists)
    else
      new ViewVlist(parentCellId, 1, null)

  prerenderHlist: (parentCellId, value) ->
    cellId = if @columnId == rootColumnId then [] else cellIdChild(parentCellId, value)
    minHeight = 1
    # TODO: More type-specific rendering?
    displayValue =
      # For now, we need to see token values in order to interpret IDs.
      # Future: Enable this again when we have a better way of rendering IDs.
      #if @type == '_token' then '*'
      if @type == '_unit' then 'X'
      # Should be OK if the user knows which columns are string-typed.
      else if typeof value == 'string' then value
      # Make sure IDs (especially) are unambiguous.
      else EJSON.stringify(value)
    vlists =
      for subsection in @subsections
        subsection.prerenderVlist(cellId)
    minHeight = Math.max(1, (vlist.minHeight for vlist in vlists)...)
    new ViewHlist(cellId, minHeight, displayValue, vlists)

  renderVlist: (vlist, height) ->
    qFamilyId = {columnId: @columnId, cellId: vlist.parentCellId}
    if vlist.hlists?
      grid = []
      for hlist in vlist.hlists
        gridVertExtend(grid, @renderHlist(hlist, hlist.minHeight))
      # Add blank cell at bottom
      if grid.length < height
        bottomGrid = gridMergedCell(height - grid.length, @width)
        bottomGrid[0][0].qFamilyId = qFamilyId
        gridVertExtend(grid, bottomGrid)
    else
      grid = gridMergedCell(height, @width, 'ERROR')
      grid[0][0].qFamilyId = qFamilyId
    grid

  renderHlist: (hlist, height) ->
    # Value
    grid = gridMergedCell(height, 1, hlist.value)
    grid[0][0].qCellId = {columnId: @columnId, cellId: hlist.cellId}
    # This logic could be in a ViewCell accessor instead, but for now it isn't
    # duplicated so there's no need.
    if @columnId != rootColumnId
      grid[0][0].qFamilyId = {columnId: @columnId, cellId: cellIdParent(hlist.cellId)}
    # Subsections
    for subsection, i in @subsections
      if @haveSeparatorColBefore[i]
        gridHorizExtend(grid, gridMergedCell(height, 1))
      subsectionGrid = subsection.renderVlist(hlist.vlists[i], height)
      gridHorizExtend(grid, subsectionGrid)
    grid

  renderHeader: (height) ->
    gridTop = gridMergedCell(height - @headerHeightBelow, @width, @col.cellName ? '', ['rsHeaderTop'])
    gridTop[0][0].columnIdTop = @columnId
    gridBelow = gridMergedCell(@headerHeightBelow - 2, 1, @col.name ? '', ['rsHeaderBelow'])
    gridBelow[0][0].columnIdBelow = @columnId
    # Hack: trim long IDs to not distort layout, unlikely to be nonunique.
    gridVertExtend(gridBelow, [[new ViewCell(@columnId.substr(0, 4))]])
    gridVertExtend(gridBelow, [[new ViewCell(
      (@type?.substr(0, 4) ? '') + (if @col.formula? then '=' else ''))]])
    # Now gridBelow is (@headerMinHeight - 1) x 1.
    for subsection, i in @subsections
      if @haveSeparatorColBefore[i]
        # Turns out class rsHeaderBelow will work for separators too.
        gridSeparator = gridMergedCell(@headerHeightBelow, 1, '', ['rsHeaderBelow'])
        gridHorizExtend(gridBelow, gridSeparator)
      gridHorizExtend(gridBelow, subsection.renderHeader(@headerHeightBelow))
    gridVertExtend(gridTop, gridBelow)
    gridTop

# XXX: OK to reference this variable from View?
viewHOT = null

# This may hold a reference to a ViewCell object from an old View.  Weird but
# shouldn't cause any problem and not worth doing differently.
selectedCell = null

newColumnArgs = new ReactiveVar(null, EJSON.equals)
newColumnKind = new ReactiveVar(null)
Template.body.helpers({
  inNewColumn: () -> newColumnArgs.get()?
})
Template.newColumn.helpers({
  # This is ridiculous: spacebars won't let us compare two strings?
  newColumnIsState: () -> newColumnKind.get() == 'state'
})
Template.newColumn.rendered = () ->
  # ensure consistent
  newColumnKind.set(@find('input[name=kind]:checked').value)
Template.newColumn.events({
  'change input[name=kind]': (event, template) ->
    newColumnKind.set(template.find('input[name=kind]:checked').value)
  'click .submit': (event, template) ->
    switch newColumnKind.get()
      when 'state'
        type = parseTypeStr(template.find('input[name=datatype]').value)
        formula = null
      when 'formula'
        type = null
        # Default formula to get the new column created ASAP.
        # Then the user can edit it as desired.
        # TODO: Change to empty set once supported.
        formula = ['var', 'this']
      else
        throw new Error()  # should not happen
    Meteor.call('defineColumn',
                newColumnArgs.get().parentId,
                newColumnArgs.get().index,
                null,  # name
                type,
                null,  # cellName
                formula,
                standardServerCallback)
    newColumnArgs.set(null)
  'click .cancel': (event, template) ->
    newColumnArgs.set(null)
})

class View

  constructor: ->
    @mainSection = new ViewSection(rootColumnId)

  hotConfig: ->
    thisView = this
    # Display the root column for completeness.  However, it doesn't have a real
    # parentCellId or value.
    hlist = @mainSection.prerenderHlist(null, '')
    grid = @mainSection.renderHeader(@mainSection.headerMinHeight)
    for row in grid
      for cell in row
        cell.cssClasses.push('htBottom', 'rsHeader')  # easiest to do here
    headerHeight = grid.length
    gridVertExtend(grid, @mainSection.renderHlist(hlist, hlist.minHeight))

    gridCaption = gridMergedCell(headerHeight - 3, 1, 'cellName', ['htMiddle', 'rsCaption'])
    gridCaption.push(
      [new ViewCell('name', 1, 1, ['rsCaption'])],
      [new ViewCell('id', 1, 1, ['rsCaption'])],
      [new ViewCell('type', 1, 1, ['rsCaption'])])
    gridVertExtend(gridCaption, gridMergedCell(
      grid.length - headerHeight, 1, 'data', ['rsCaption']))
    gridHorizExtend(gridCaption, grid)
    grid = gridCaption
    @grid = grid

    d = {
      readOnly: true
      data: ((cell.value for cell in row) for row in grid)
      # Separator columns are 8 pixels wide.  Others use default width.
      colWidths: (for cell in grid[headerHeight - 2]  # id row (hack)
                    if cell.value then undefined else 8)
      cells: (row, col, prop) ->
        {className: grid[row][col].cssClasses.join(' ')}
      # TODO: Make this work again if desired (Matt is not convinced).
      #!afterGetColHeader: (col, TH) =>
      #!  if header[col+1] == ''
      #!    ($ TH) .addClass 'incomparable'
      #!columns: (for n in header
      #!            if n then {} else {className: 'incomparable'})\
      #!         [1..] .concat [{}]
      autoColumnSize: true
      mergeCells: [].concat((
        for row,i in grid
          for cell,j in row when cell.rowspan != 1 || cell.colspan != 1
            {row: i, col: j, rowspan: cell.rowspan, colspan: cell.colspan}
        )...)

      # Seems more helpful to the user (e.g., when scrolling the browser window).
      # See if we have trouble with the user needing to "escape" from the table.
      outsideClickDeselects: false

      # Try to put the selection somewhere reasonable after the table is reloaded.
      afterDeselect: () ->
        selectedCell = null
      afterSelectionEnd: (r1, c1, r2, c2) ->
        selectedCell = thisView.getSingleSelectedCell()

      contextMenu: {
        # TODO: Implement commands.
        items: {
          # Future: Would be nice to move selection appropriately on column
          # insert/delete, but this is a less common case.

          # addColumnLeft is redundant but nice for users.
          addColumnLeft: {
            name: 'Insert column on the left'
            disabled: () ->
              !((c = thisView.getSingleSelectedCell())? &&
                (ci = c.columnIdTop)? && ci != rootColumnId)
            callback: () ->
              c = thisView.getSingleSelectedCell()
              ci = c.columnIdTop
              col = Columns.findOne(ci)
              parentId = col.parent
              parentCol = Columns.findOne(parentId)
              index = parentCol.children.indexOf(ci)
              newColumnArgs.set({parentId: parentId, index: index})
          }
          addColumnRight: {
            name: 'Insert column on the right'
            disabled: () ->
              !((c = thisView.getSingleSelectedCell())? &&
                (ci = c.columnIdTop ? c.columnIdBelow)? && ci != rootColumnId)
            callback: () ->
              c = thisView.getSingleSelectedCell()
              if (ci = c.columnIdTop)?
                # Like addColumnLeft except + 1
                col = Columns.findOne(ci)
                parentId = col.parent
                parentCol = Columns.findOne(parentId)
                index = parentCol.children.indexOf(ci) + 1
              else
                # Child of the selected column
                parentId = c.columnIdBelow
                index = 0
              newColumnArgs.set({parentId: parentId, index: index})
          }
          deleteColumn: {
            name: 'Delete column'
            disabled: () ->
              # Future: Support recursive delete.
              # CLEANUP: This is a mess; find a way to share the code or publish from the server.
              !((c = thisView.getSingleSelectedCell())? &&
                (ci = c.columnIdTop ? c.columnIdBelow)? && ci != rootColumnId &&
                (col = Columns.findOne(ci)).children.length == 0 &&
                !(columnIsState(col) && col.numStateCells > 0))
            callback: () ->
              c = thisView.getSingleSelectedCell()
              Meteor.call('deleteColumn',
                          c.columnIdTop ? c.columnIdBelow,
                          standardServerCallback)
          }
          sep1: '----------'
          addStateCell: {
            name: 'Add cell to this set'
            disabled: () ->
              !((c = thisView.getSingleSelectedCell())? &&
                c.qFamilyId? && columnIsState(Columns.findOne(c.qFamilyId.columnId)))
            callback: () ->
              c = thisView.getSingleSelectedCell()
              alert('Unimplemented')
              #Meteor.call('writeState', c.qFamilyId, TODO, false)
          }
          deleteStateCell: {
            name: 'Delete cell'
            disabled: () ->
              !((c = thisView.getSingleSelectedCell())? &&
                c.qCellId? && columnIsState(Columns.findOne(c.qCellId.columnId)))
            callback: () ->
              c = thisView.getSingleSelectedCell()
              # For now, if there are descendants, an error will be logged in the developer console.
              Meteor.call('writeState',
                          {columnId: c.qCellId.columnId, cellId: cellIdParent(c.qCellId.cellId)},
                          cellIdLastStep(c.qCellId.cellId), false,
                          standardServerCallback)
          }
        }
      }
    }
    d

  getSingleSelectedCell: =>
    s = viewHOT.getSelected()
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

  selectSingleCell: (r1, c1) ->
    cell = @grid[r1][c1]
    viewHOT.selectCell(r1, c1, r1 + cell.rowspan - 1, c1 + cell.colspan - 1)

  selectMatchingCell: (predicate) ->
    for i in [0..@grid.length-1] by 1
      for j in [0..@mainSection.width-1] by 1
        if predicate(@grid[i][j])
          @selectSingleCell(i, j)
          return true
    return false

rebuildView = () ->
  if viewHOT
    viewHOT.destroy()
    viewHOT = null
  try
    view = new View()
    hotConfig = view.hotConfig()
  catch e
    if e instanceof NotReadyError
      return  # Let the autorun run again once we have the data.
    throw e
  viewHOT = new Handsontable($('#View')[0], hotConfig)
  # Try to select a cell similar to the one previously selected.
  if selectedCell?
    ((selectedCell.qCellId? &&
      view.selectMatchingCell((c) -> EJSON.equals(selectedCell.qCellId, c.qCellId))) ||
     (selectedCell.qFamilyId? &&
      view.selectMatchingCell((c) -> EJSON.equals(selectedCell.qFamilyId, c.qFamilyId))) ||
     (selectedCell.qFamilyId? &&
      view.selectMatchingCell((c) -> EJSON.equals(selectedCell.qFamilyId.columnId, c.columnIdBelow))) ||
     (selectedCell.columnIdTop? &&
      view.selectMatchingCell((c) -> EJSON.equals(selectedCell.columnIdTop, c.columnIdTop))) ||
     (selectedCell.columnIdBelow? &&
      view.selectMatchingCell((c) -> EJSON.equals(selectedCell.columnIdBelow, c.columnIdBelow))) ||
     false)

Meteor.startup () ->
  # Load order...
  @FamilyData = new Mongo.Collection(FAMILY_DATA_COLLECTION)
  @FormulaColumnType = new Mongo.Collection(FORMULA_COLUMN_TYPE_COLLECTION)

  Tracker.autorun(rebuildView)
