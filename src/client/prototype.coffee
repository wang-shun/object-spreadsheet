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
  constructor: (@parentCellId, @minHeight, @hlists, @error) ->

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
    @width = 1
    @leftEdgeSingular = true
    @rightEdgeSingular = true
    # field index -> bool (have a separator column before this field)
    @haveSeparatorColBefore = []
    @subsections = []
    @headerHeightBelow = 2  # valueName, type
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
    # XXX: Detect NotReadyError
    ce = Cells.findOne({column: @columnId, key: parentCellId}) ? {values: []}
    if ce.values?
      hlists =
        for value in ce.values
          @prerenderHlist(cellIdChild(parentCellId, value), value)
      minHeight = 0
      for hlist in hlists
        minHeight += hlist.minHeight
      # Don't add any extra rows: it's looking ridiculous.  Once we know which
      # columns are plural, we can reconsider adding extra rows.
      new ViewVlist(parentCellId, minHeight, hlists)
    else
      new ViewVlist(parentCellId, 1, null, ce.error)

  prerenderHlist: (cellId, value) ->
    minHeight = 1
    # TODO: More type-specific rendering?
    displayValue =
      if @type == '_token' then '*'
      # Show _unit values for now so we can see if they aren't 'X'.
      #if @type == '_unit' then 'X'
      else if !typeIsPrimitive(@type) then new CellReference({columnId: @type, cellId: value})
      # Should be OK if the user knows which columns are string-typed.
      else if typeof value == 'string' then value
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
      grid = gridMergedCell(height, @width, '!')
      grid[0][0].fullText = vlist.error
      grid[0][0].qFamilyId = qFamilyId
    grid

  renderHlist: (hlist, height) ->
    # Value
    value = hlist.value
    grid = gridMergedCell(height, 1, value)
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
    gridTop = gridMergedCell(
      (if height?
        [height - @headerHeightBelow, @width]
      else
        [1, 1])...,
      @col.cellName ? '', ['rsHeaderTop'])
    gridTop[0][0].columnId = @columnId
    gridTop[0][0].kind = 'top'
    gridTop[0][0].fullText = @columnId
    gridBelow = gridMergedCell(
      if height? then @headerHeightBelow - 1 else 1,
      1, @col.name ? '', ['rsHeaderBelow'])
    gridBelow[0][0].columnId = @columnId
    gridBelow[0][0].kind = 'below'
    typeName = (s) ->
      if !s then ''
      else if typeIsPrimitive(s) then s
      else Columns.findOne(s)?.cellName ? (""+s)[...4]
    # XXX: The value in the cell is not consistent with what we allow the user
    # to type in the cell!
    typeCell = new ViewCell(
      (if @col.formula? then '=' else '') +
      (if @col.specifiedType? then typeName(@type) else "(#{typeName(@type)})") +
      (if @col.typecheckError? then '!' else ''))
    typeCell.fullText = (
      (@type ? '') + (if @col.specifiedType? then ' (specified)' else '') +
      (if @col.formula? then ' (formula)' else '') +
      (if @col.typecheckError? then " (TYPECHECK ERROR: #{@col.typecheckError})" else ''))
    typeCell.columnId = @columnId
    typeCell.kind = 'type'
    gridVertExtend(gridBelow, [[typeCell]])
    if height?
      # Now gridBelow is (@headerMinHeight - 1) x 1.
      for subsection, i in @subsections
        if @haveSeparatorColBefore[i]
          # Turns out class rsHeaderBelow will work for separators too.
          gridSeparator = gridMergedCell(@headerHeightBelow, 1, '', ['rsHeaderBelow'])
          gridHorizExtend(gridBelow, gridSeparator)
        gridHorizExtend(gridBelow, subsection.renderHeader(@headerHeightBelow))
      gridVertExtend(gridTop, gridBelow)
    else
      gridVertExtend(gridTop, gridBelow)
      for subsection, i in @subsections
        if @haveSeparatorColBefore[i]
          gridSeparator = gridMergedCell(gridTop.length, 1)
          gridHorizExtend(gridTop, gridSeparator)
        gridHorizExtend(gridTop, subsection.renderHeader(null))
    gridTop

# This may hold a reference to a ViewCell object from an old View.  Weird but
# shouldn't cause any problem and not worth doing differently.
selectedCell = null

onSelection = () ->
  selectedCell = view.getSingleSelectedCell()
  fullTextToShow.set(selectedCell?.fullText)
  # _id: Hacks to get the #each to clear the forms when the cell changes.
  addStateCellArgs.set(
    if (qf = selectedCell?.qFamilyId)? && columnIsState(col = getColumn(qf.columnId))
      [{
        _id: EJSON.stringify(qf)
        qFamilyId: qf
        canAddValue: col.type not in ['_token', '_unit']
        canAddToken: col.type == '_token'
        # Adding a duplicate value has no effect, but disallow it as a
        # hint to the user.
        canAddUnit: (col.type == '_unit' &&
                     !Cells.findOne({column: qf.columnId, key: qf.cellId})?.values?.length)
      }]
    else
      []
  )
  changeFormulaArgs.set(
    # This intentionally shows only for the 'below' cell, because the 'below'
    # cell represents the values (which is what a formula generates) while the
    # 'top' cell represents the cells.
    if selectedCell? && selectedCell.kind == 'below' &&
       (ci = selectedCell.columnId) != rootColumnId
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
    type = getColumn(qFamilyId.columnId).type
    if !typeIsPrimitive(type)
      if (m = /^@(\d+)$/.exec(text))
        wantRowNum = Number.parseInt(m[1])
        for [qCellId, rowNum] in view.qCellIdToRowNum.entries()
          if qCellId.columnId == type && rowNum == wantRowNum
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
    else if type == '_string'
      text
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
    oldValue = cellIdLastStep(qCellId.cellId)
    if (newValue = @parseValueUi(
        {columnId: qCellId.columnId, cellId: key}, enteredValue))?
      # TODO check if cell has children!
      new ColumnBinRel(qCellId.columnId)
        .removeAdd key, oldValue, newValue, callback

  @removeCell: (qCellId, callback=->) ->
    key = cellIdParent(qCellId.cellId)
    oldValue = cellIdLastStep(qCellId.cellId)
    # TODO check if cell has children!
    new ColumnBinRel(qCellId.columnId)
      .remove key, oldValue, callback

  @canEdit: (columnId) ->
    col = getColumn(columnId)
    # May as well not let the user try to edit _unit.
    col? && columnIsState(col) && col.type not in ['_token', '_unit']

changeFormulaArgs = new ReactiveVar([], EJSON.equals)
# We mainly care that this doesn't crash.
origFormulaStrForColumnId = (columnId) ->
  formula = getColumn(columnId)?.formula
  if formula? then stringifyFormula(formula) else ''
newFormulaStr = new ReactiveVar(null)
Template.changeFormula.rendered = () ->
  orig = origFormulaStrForColumnId(Template.currentData().columnId)
  newFormulaStr.set(orig)
  # Handles case when showing only the "Create formula" button for a non-formula column.
  if orig
    @find('input[name=formula]').value = orig
Template.changeFormula.helpers
  formula: ->
    origFormulaStrForColumnId(@columnId)
  formulaClass: ->
    if newFormulaStr.get() != origFormulaStrForColumnId(@columnId)
      'formulaModified'
    else
      ''

Template.changeFormula.events({
  'input .formula': (event, template) ->
    newFormulaStr.set(template.find('input[name=formula]').value)
  'submit form': (event, template) ->
    formulaStr = newFormulaStr.get()
    try
      formula = parseFormula(getColumn(@columnId).parent, formulaStr)
    catch e
      unless e instanceof FormulaValidationError
        throw e
      alert('Failed to parse formula: ' + e.message)
      return false
    # Canonicalize the string in the field, otherwise the field might stay
    # yellow after successful submission.
    template.find('input[name=formula]').value = stringifyFormula(formula)
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
    formula = ['lit', '_unit', []]
    Meteor.call 'changeColumnFormula', $$, @columnId, formula,
                standardServerCallback
    # TODO warn user if column has data!!
  'keydown form': (event, template) ->
    if (event.which == 27) then template.find("[type=reset]")?.click()
})

insertBlankColumn = (parentId, index) ->
  # Obey the restriction on a state column as child of a formula column.
  # Although changeColumnFormula allows this to be bypassed anyway... :(
  formula = if getColumn(parentId).formula? then ['lit', '_unit', []] else null
  Meteor.call('defineColumn', $$,
              parentId,
              index,
              null,  # name
              null,  # type
              null,  # cellName
              formula,  # formula
              standardServerCallback)


headerExpanded = new ReactiveVar(true)
@toggleHeaderExpanded = () ->
  headerExpanded.set(!headerExpanded.get())

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
    # value.
    hlist = @mainSection.prerenderHlist([], '')
    grid = @mainSection.renderHeader(
      if headerExpanded.get() then @mainSection.headerMinHeight else null)
    for row in grid
      for cell in row
        cell.cssClasses.push('htBottom', 'rsHeader')  # easiest to do here
    headerHeight = grid.length
    gridData = @mainSection.renderHlist(hlist, hlist.minHeight)

    # Resolve cell cross-references.
    @qCellIdToRowNum = new EJSONKeyedMap()
    for row, i in gridData
      for cell in row
        if cell.qCellId?
          # User-facing row numbers are one-based.
          @qCellIdToRowNum.set(cell.qCellId, i+1)
    for row in gridData
      for cell in row
        if cell.value instanceof CellReference
          # Future: We might want to save the original ID if it helps us jump to
          # the cell.  In general, we might want to save the original value to
          # facilitate editing it in an appropriate widget.
          cell.value = '@' + @qCellIdToRowNum.get(cell.value.qCellId)
    gridVertExtend(grid, gridData)

    # This is terrible but it will take ten times as long to do properly...
    cnHtml = ("<input type='button' value='#{if headerExpanded.get() then '-' else '+'}'" +
              " onclick='toggleHeaderExpanded();'/>CN")
    gridCaption = gridMergedCell(headerHeight - 2, 1, cnHtml, ['htMiddle', 'rsCaption'])
    gridCaption.push(
      [new ViewCell('VN', 1, 1, ['rsCaption'])],
      [new ViewCell('Type', 1, 1, ['rsCaption'])])
    gridVertExtend(gridCaption,
                   ([new ViewCell(i+1, 1, 1, ['rsCaption'])] for i in [0..gridData.length-1]))
    gridHorizExtend(gridCaption, grid)
    grid = gridCaption
    @grid = grid

    separatorColumns = (i for cell,i in grid[headerHeight - 1] when i != 0 && !cell.columnId)
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
          renderer: if col == 0 then 'html' else 'text'
          className: (cell.cssClasses.concat colClasses).join(' ')
          # Only column header "top" and "below" cells can be edited,
          # for the purpose of changing the cellName and name respectively.
          readOnly: !(cell.kind in ['top', 'below', 'type'] && cell.columnId != rootColumnId ||
                      cell.qCellId? && StateEdit.canEdit(cell.qCellId.columnId))
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
            Meteor.call 'changeColumnCellName', $$, cell.columnId, newVal,
                        standardServerCallback
          if cell.kind == 'below'
            Meteor.call 'changeColumnName', $$, cell.columnId, newVal,
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

          # addSiblingLeft is redundant but nice for users.
          addSiblingLeft: {
            name: 'Insert left sibling column'
            disabled: () =>
              c = @getSingleSelectedCell()
              !((ci = c?.columnId)? && ci != rootColumnId)
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
          addSiblingRight: {
            name: 'Insert right sibling column'
            disabled: () =>
              c = @getSingleSelectedCell()
              !((ci = c?.columnId)? && ci != rootColumnId)
            callback: () =>
              c = @getSingleSelectedCell()
              ci = c.columnId
              col = getColumn(ci)
              parentId = col.parent
              parentCol = getColumn(parentId)
              index = parentCol.children.indexOf(ci) + 1
              @hot.deselectCell()
              insertBlankColumn parentId, index
          }
          addChildFirst: {
            name: 'Insert first child column'
            disabled: () =>
              c = @getSingleSelectedCell()
              !(c?.columnId)?
            callback: () =>
              c = @getSingleSelectedCell()
              ci = c.columnId
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
                !((col = getColumn(ci))?.children?.length))
            callback: () =>
              c = @getSingleSelectedCell()
              ci = c && (c.columnId ? c.qFamilyId?.columnId)
              @hot.deselectCell() # <- Otherwise changeFormula form gets hosed.
              Meteor.call('deleteColumn', $$, ci,
                          standardServerCallback)
          }
          sep1: '----------'
          # Future: Consider enabling.  I'm not sure what is the best UI. ~ Matt
          ###
          addAutomaticStateCell: {
            name: 'Add cell'
            disabled: () =>
              c = @getSingleSelectedCell()
              !(c? && (qf = c.qFamilyId)? &&
                columnIsState(col = getColumn(qf.columnId)) &&
                # Adding a duplicate value has no effect, but disallow it as a
                # hint to the user.
                !(col.type == '_unit' &&
                  Cells.findOne({column: qf.columnId, key: qf.cellId})?.values?.length))
            callback: () =>
              c = @getSingleSelectedCell()
              qf = c.qFamilyId
              if getColumn(qf.columnId).type in ['_unit', '_token']
                StateEdit.addCell c.qFamilyId, null, standardServerCallback
              else
                # Didn't work without the setTimeout.  Maybe the dismissal of
                # the context menu is reselecting the table cell?  Obviously
                # this approach doesn't scale when Handsontable starts using
                # setTimeout(0)...
                # - Doesn't work when the form hasn't been rendered yet!
                setTimeout((=>
                    @hot.unlisten()
                    $('#addStateCell-value')[0].focus()),
                  0)
          }
          ###
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


Meteor.subscribe "cells"
Meteor.subscribe "views"

view = null
viewHOT = null


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
  exported {view, viewHOT}  # for debugging
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
  sheet = @data?.sheet || ''
  viewId = @data?.viewId
  Tablespace.default = Tablespace.get sheet
  Meteor.call 'open', $$
  Tracker.autorun(guarded -> rebuildView readViewDef viewId)


Meteor.methods({
  # Implement these two methods to reduce display jankiness, since they're easy.
  # Hm, doesn't help much, I suspect the bottleneck is rerendering the table,
  # not the server call.
  changeColumnName: (cc, columnId, name) ->
    Columns.update(columnId, {$set: {name: name}})
  changeColumnCellName: (cc, columnId, cellName) ->
    Columns.update(columnId, {$set: {cellName: cellName}})
})

$ ->
  exported {View, rebuildView}
