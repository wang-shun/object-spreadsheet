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

Router.route "/", -> @render "Spreadsheet"
Router.route "/views/:_id", ->
  @render "Spreadsheet", {data: {viewId: @params._id}}
Router.route "/schema"

# Grid utilities

class ViewCell
  constructor: (@value = '', @rowspan = 1, @colspan = 1, @cssClasses = []) ->
    @qFamilyId = null
    @qCellId = null
    @columnId = null
    @kind = null
    @fullText = null

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

  constructor: (@layoutTree) ->
    @columnId = @layoutTree.root
    @col = getColumn(@columnId)
    unless @col?
      throw new NotReadyError()
    # Future: Set this when we know it.
    @relationSingular = false
    # Might be undefined (root cell or no cells), fail gently.
    @type = @col.type
    #  if @col.formula? then FormulaColumnType.findOne(@columnId)?.type
    #  else @col.type
    @width = 1
    @leftEdgeSingular = true
    @rightEdgeSingular = true
    # field index -> bool (have a separator column before this field)
    @haveSeparatorColBefore = []
    @subsections = []
    @headerHeightBelow = 3  # name, id, type
    for sublayout in @layoutTree.subtrees
      subsection = new ViewSection(sublayout)
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
    column = new ColumnBinRel(@columnId)
    familyData = column.lookup(set([parentCellId]))
    if 1  # TODO familyData.state == FAMILY_SUCCESS
      hlists =
        for value in familyData.set.elements()
          @prerenderHlist(parentCellId, value)
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
      # Show _unit values for now so we can see if they aren't 'X'.
      #if @type == '_unit' then 'X'
      # Should be OK if the user knows which columns are string-typed.
      if typeof value == 'string' then value
      else if value?.error? then {text: "!", fullText: value.error}
      # Make sure IDs (especially) are unambiguous.
      else JSON.stringify(value)
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
    value = hlist.value
    grid = gridMergedCell(height, 1, value.text ? value)
    grid[0][0].qCellId = {columnId: @columnId, cellId: hlist.cellId}
    if value.fullText?
      grid[0][0].fullText = value.fullText
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
    gridTop[0][0].columnId = @columnId
    gridTop[0][0].kind = 'top'
    gridBelow = gridMergedCell(@headerHeightBelow - 2, 1, @col.name ? '', ['rsHeaderBelow'])
    gridBelow[0][0].columnId = @columnId
    gridBelow[0][0].kind = 'below'
    # Hack: trim long IDs to not distort layout, unlikely to be nonunique.
    idCell = new ViewCell(@columnId.substr(0, 4))
    idCell.fullText = @columnId
    typeName = (s) ->
      if !s then ''
      else if _.isArray(s) then (typeName(x) for x in s)
      else if typeIsPrimitive(s) then s
      else Columns.findOne(s)?.cellName ? (""+s)[...4]
    typeCell = new ViewCell(
      (if @col.formula? then '=' else '') + typeName(@type))
    typeCell.fullText = (@type ? '') + (if @col.formula? then ' (formula)' else '')
    typeCell.columnId = @columnId
    typeCell.kind = 'type'
    gridVertExtend(gridBelow, [[idCell]])
    gridVertExtend(gridBelow, [[typeCell]])
    # Now gridBelow is (@headerMinHeight - 1) x 1.
    for subsection, i in @subsections
      if @haveSeparatorColBefore[i]
        # Turns out class rsHeaderBelow will work for separators too.
        gridSeparator = gridMergedCell(@headerHeightBelow, 1, '', ['rsHeaderBelow'])
        gridHorizExtend(gridBelow, gridSeparator)
      gridHorizExtend(gridBelow, subsection.renderHeader(@headerHeightBelow))
    gridVertExtend(gridTop, gridBelow)
    gridTop

# This may hold a reference to a ViewCell object from an old View.  Weird but
# shouldn't cause any problem and not worth doing differently.
selectedCell = null

onSelection = () ->
  selectedCell = view.getSingleSelectedCell()
  fullTextToShow.set(selectedCell?.fullText)
  # _id: Hacks to get the #each to clear the forms when the cell changes.
  addStateCellArgs.set(
    if (qf = selectedCell?.qFamilyId)? && columnIsState(getColumn(qf.columnId))
      [{_id: EJSON.stringify(qf), qFamilyId: qf}]
    else
      []
  )
  changeFormulaArgs.set(
    if selectedCell? && selectedCell.kind? && selectedCell.colspan == 1 &&
       !selectedCell.fullText? &&  # <- currently occupies the same spot, looks ugly
       (ci = selectedCell.columnId)? # && getColumn(ci).formula?
      [{_id: ci, columnId: ci}]
    else
      []
  )

fullTextToShow = new ReactiveVar(null)

Template.formulaValueBar.helpers({
  fullTextToShow: () -> fullTextToShow.get()
  addStateCellArgs: () -> addStateCellArgs.get()
  changeFormulaArgs: () -> changeFormulaArgs.get()
})

addStateCellArgs = new ReactiveVar([], EJSON.equals)
Template.addStateCell.events({
  'submit form': (event, template) ->
    valueStr = template.find('input[name=value]').value
    StateEdit.addCell @qFamilyId, valueStr,
    # Clear the field on successful submission (only)
    andThen -> template.find('input[name=value]').value = ''
    false # prevent clear
})

class StateEdit

  @parseValue: (type, text) ->
    if type in ['_string', '_token', '_unit']
      text
    else
      JSON.parse text

  @parseValueUi: (columnId, text) ->
    col = getColumn(columnId)
    try
      @parseValue col.type, text
    catch e
      alert('Invalid value: ' + e.message)
      null

  @addCell: (qFamilyId, enteredValue, callback=->) ->
    if (value = @parseValueUi qFamilyId.columnId, enteredValue)?
      key = qFamilyId.cellId
      new ColumnBinRel(qFamilyId.columnId)
        .add key, value, callback

  @modifyCell: (qCellId, enteredValue, callback=->) ->
    if (newValue = @parseValueUi qCellId.columnId, enteredValue)?
      key = cellIdParent(qCellId.cellId)
      value = cellIdLastStep(qCellId.cellId)
      # TODO check if cell has children!
      new ColumnBinRel(qCellId.columnId)
        .removeAdd key, value, newValue, callback

  @removeCell: (qCellId, callback=->) ->
    key = cellIdParent(qCellId.cellId)
    value = cellIdLastStep(qCellId.cellId)
    # TODO check if cell has children!
    new ColumnBinRel(qCellId.columnId)
      .remove key, value, callback

  @canEdit: (qCellId) ->
    col = getColumn(qCellId.columnId)
    col? && columnIsState(col) && !columnIsToken(col)

changeFormulaArgs = new ReactiveVar([], EJSON.equals)
newFormulaStr = new ReactiveVar(null)
Template.changeFormula.rendered = () ->
  col = getColumn(Template.currentData().columnId)
  if col?.formula?
    orig = JSON.stringify(col.formula)
    newFormulaStr.set(orig)
    @find('input[name=formula]').value = orig
Template.changeFormula.helpers
  formula: ->
    col = getColumn @columnId
    col.formula
  formulaClass: ->
    col = getColumn @columnId
    if col?.formula?
      orig = JSON.stringify(col.formula)
      entered = newFormulaStr.get()
      if orig != entered then 'formulaModified' else ''

Template.changeFormula.events({
  'input .formula': (event, template) ->
    newFormulaStr.set(template.find('input[name=formula]').value)
  'submit form': (event, template) ->
    formulaStr = template.find('input[name=formula]').value
    try
      formula = JSON.parse(formulaStr)
    catch e
      alert('Invalid JSON.')
      return false
    # Canonicalize the string in the field, otherwise the field might stay
    # yellow after successful submission.
    template.find('input[name=formula]').value = JSON.stringify(formula)
    Meteor.call('changeColumnFormula',
                @columnId,
                formula,
                standardServerCallback)
    false # prevent refresh
  'click [type=reset]': (event, template) ->
    orig = JSON.stringify(getColumn(@columnId).formula)
    newFormulaStr.set(orig)
    template.find('input[name=formula]').value = orig
    false # prevent clear
  'click .create': (event, template) ->
    # Default formula to get the new column created ASAP.
	# Then the user can edit it as desired.
    formula = ['lit', '_unit', []]
    Meteor.call 'changeColumnFormula', @columnId, formula,
                standardServerCallback
    # TODO warn user if column has data!!
  'keydown form': (event, template) ->
    if (event.which == 27) then template.find("[type=reset]")?.click()
})

insertBlankColumn = (parentId, index) ->
  Meteor.call('defineColumn',
              parentId,
              index,
              null,  # name
              null,  # type
              null,  # cellName
              null,  # formula
              standardServerCallback)


class View

  constructor: (@viewDef) ->
    @reload()
    @hot = null

  @rootLayout: -> @drillDown(rootColumnId).filter (x) => !@ownerView(x)

  @drillDown: (startingColumnId) ->
    children = Columns.findOne(startingColumnId)?.children || []
    new Tree(startingColumnId, (@drillDown child for child in children))

  @ownerView: (columnId) ->
    Columns.findOne(columnId)?.view

  reload: (viewDef) ->
    @viewDef = viewDef || @viewDef
    @layoutTree = @viewDef?.layout || View.rootLayout()
    @mainSection = new ViewSection(@layoutTree)

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

    separatorColumns = (i for cell,i in grid[headerHeight - 2] when !(cell.value))
    @separatorColumns = separatorColumns

    d = {
      data: ((cell.value for cell in row) for row in grid)
      # Separator columns are 8 pixels wide.  Others use default width.
      colWidths: (for i in [0..@mainSection.width]
                    if i in separatorColumns then 10 else undefined)
      cells: (row, col, prop) =>
        cell = @grid[row]?[col]
        if !cell then return {}  # may occur if grid is changing
        adjcol = col+cell.colspan
        colClasses = if col in @separatorColumns then ['separator'] else
                     if adjcol in @separatorColumns then ['incomparable'] else []
        {
          className: (cell.cssClasses.concat colClasses).join(' ')
          # Only column header "top" and "below" cells can be edited,
          # for the purpose of changing the cellName and name respectively.
          readOnly: !(cell.kind in ['top', 'below'] ||
                      cell.kind == 'type' && columnIsState(getColumn(cell.columnId)) ||
                      cell.qCellId? && StateEdit.canEdit(cell.qCellId))
        }
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
        onSelection()

      afterSelectionEnd: (r1, c1, r2, c2) ->
        onSelection()

      beforeChange: (changes, source) =>
        for [row, col, oldVal, newVal] in changes
          cell = @grid[row][col]
          # One of these cases should apply...
          if cell.kind == 'top'
            Meteor.call 'changeColumnCellName', cell.columnId, newVal,
                        standardServerCallback
          if cell.kind == 'below'
            Meteor.call 'changeColumnName', cell.columnId, newVal,
                        standardServerCallback
          if cell.kind == 'type'
            Meteor.call 'changeColumnType', cell.columnId, newVal,
                        standardServerCallback
          if cell.qCellId?
            if newVal
              StateEdit.modifyCell cell.qCellId, newVal
            else
              StateEdit.removeCell cell.qCellId
        # Don't apply the changes directly; let them come though the Meteor
        # stubs.  This ensures that they get reverted by Meteor if the server
        # call fails.
        return false

      contextMenu: {
        # TODO: Implement commands.
        items: {
          # Future: Would be nice to move selection appropriately on column
          # insert/delete, but this is a less common case.

          # addColumnLeft is redundant but nice for users.
          addColumnLeft: {
            name: 'Insert column on the left'
            disabled: () =>
              c = @getSingleSelectedCell()
              !((ci = c?.columnId)? && ci != rootColumnId && c.kind == 'top')
            callback: () =>
              c = @getSingleSelectedCell()
              ci = c.columnId
              col = getColumn(ci)
              parentId = col.parent
              parentCol = getColumn(parentId)
              index = parentCol.children.indexOf(ci)
              @hot.deselectCell()
              insertBlankColumn parentId, index
          }
          addColumnRight: {
            name: 'Insert column on the right'
            disabled: () =>
              c = @getSingleSelectedCell()
              # TODO refine this condition
              !((ci = c?.columnId)? && (c.kind == 'top' && ci != rootColumnId ||
                                        c.kind =='below'))
            callback: () =>
              c = @getSingleSelectedCell()
              ci = c.columnId
              if c.kind == 'top'
                # Like addColumnLeft except + 1
                col = getColumn(ci)
                parentId = col.parent
                parentCol = getColumn(parentId)
                index = parentCol.children.indexOf(ci) + 1
              else
                # Child of the selected column
                parentId = ci
                index = 0
              @hot.deselectCell()
              insertBlankColumn parentId, index
          }
          deleteColumn: {
            name: 'Delete column'
            disabled: () =>
              c = @getSingleSelectedCell()
              ci = c && (c.columnId ? c.qFamilyId?.columnId)
              # Future: Support recursive delete.
              # CLEANUP: This is a mess; find a way to share the code or publish from the server.
              !(ci? && ci != rootColumnId &&
                !((col = getColumn(ci))?.children?.length) &&
                !(columnIsState(col) && col.numStateCells > 0))

            callback: () =>
              c = @getSingleSelectedCell()
              ci = c && (c.columnId ? c.qFamilyId?.columnId)
              @hot.deselectCell() # <- Otherwise changeFormula form gets hosed.
              Meteor.call('deleteColumn', ci,
                          standardServerCallback)
          }
          sep1: '----------'
          deleteStateCell: {
            name: 'Delete cell'
            disabled: () =>
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

  hotReconfig: (hot) ->
    d = @hotConfig()
    ## Crazy hack!
    @hot = hot = hot ? @hot
    MergeCells = hot.mergeCells.constructor
    hot.mergeCells = new MergeCells(d.mergeCells)
    hot.updateSettings {colWidths: d.colWidths}
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

  selectSingleCell: (r1, c1) ->
    cell = @grid[r1][c1]
    @hot.selectCell(r1, c1, r1 + cell.rowspan - 1, c1 + cell.colspan - 1)

  selectMatchingCell: (predicate) ->
    for i in [0..@grid.length-1] by 1
      for j in [0..@mainSection.width-1] by 1
        if predicate(@grid[i][j])
          @selectSingleCell(i, j)
          return true
    return false


Meteor.subscribe "columns"
Meteor.subscribe "cells"
Meteor.subscribe "views"

view = null
viewHOT = null

#viewId = null
#layoutTree = null


readViewDef = (viewId) ->
  if viewId?
    if (v = Views.findOne "" + viewId)? then v
    else throw new NotReadyError
  else
    null

rebuildView = (viewDef) ->
  if !view || !viewHOT
    if viewHOT
      viewHOT.destroy()
      viewHOT = null
      view = null
    view = new View viewDef
    viewHOT = view.hotCreate $('#View')[0]
  else
    view.reload viewDef
    view.hotReconfig()
  # Try to select a cell similar to the one previously selected.
  if selectedCell?
    ((selectedCell.qCellId? &&
      view.selectMatchingCell((c) -> EJSON.equals(selectedCell.qCellId, c.qCellId))) ||
     (selectedCell.qFamilyId? &&
      view.selectMatchingCell((c) -> EJSON.equals(selectedCell.qFamilyId, c.qFamilyId))) ||
     (selectedCell.qFamilyId? &&
      view.selectMatchingCell((c) -> c.kind == 'below' &&
                                     EJSON.equals(selectedCell.qFamilyId.columnId, c.columnId))) ||
     (selectedCell.kind? &&
      view.selectMatchingCell((c) -> selectedCell.kind == c.kind &&
                                     EJSON.equals(selectedCell.columnId, c.columnId))) ||
     false)

# Helper decorator for use with Tracker.autorun
guarded = (op) ->
  ->
    try
      op arguments...
    catch e
      if e instanceof NotReadyError
        return  # Let the autorun run again once we have the data.
      throw e


Template.Spreadsheet.rendered = ->
  viewId = @data?.viewId
  Tracker.autorun(guarded -> rebuildView readViewDef viewId)


Meteor.startup () ->
  # Load order...
  @FamilyData = new Mongo.Collection(FAMILY_DATA_COLLECTION)
  @FormulaColumnType = new Mongo.Collection(FORMULA_COLUMN_TYPE_COLLECTION)


Meteor.methods({
  # Implement these two methods to reduce display jankiness, since they're easy.
  # Hm, doesn't help much, I suspect the bottleneck is rerendering the table,
  # not the server call.
  changeColumnName: (columnId, name) ->
    Columns.update(columnId, {$set: {name: name}})
  changeColumnCellName: (columnId, cellName) ->
    Columns.update(columnId, {$set: {cellName: cellName}})
})

$ ->
  exported {View, rebuildView}
