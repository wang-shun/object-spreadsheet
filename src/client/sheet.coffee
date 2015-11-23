
# Is this where we want routes to be?

Router.route "/", -> @render "Spreadsheet"  # @deprecated (should show list of avail sheets)

Router.route "/:sheet", ->
  @render "Spreadsheet", data: {sheet: @params.sheet}
Router.route "/:sheet/views/:_id", ->
  @render "Spreadsheet", data: {sheet: @params.sheet, viewId: @params._id}


NotReadyError = Meteor.makeErrorType('NotReadyError',
  class NotReadyError
    constructor: (@message) ->
)

# Object that can be used as ViewCell.value or ViewHlist.value to defer the
# resolution of the target cell ID to a row number.  I'm a terrible person for
# taking advantage of heterogeneous fields in JavaScript... ~ Matt
class @CellReference
  constructor: (@qCellId, @display) ->

@stringifyTypeForSheet = (type) ->
  if type == '_unit' then 'X'
  else if typeIsReference(type) then Columns.findOne(type)?.objectName ? (""+type)[...4]
  else type

@markDisplayClassesForType = (type) ->
  if type == '_unit' then ['centered'] else []

class ViewVlist
  constructor: (@parentCellId, @minHeight, @hlists, @error) ->

class ViewHlist
  constructor: (@cellId, @minHeight, @value, @error, @vlists) ->

class ViewSection

  constructor: (@layoutTree, @options={}) ->
    @columnId = @layoutTree.root
    @col = getColumn(@columnId)
    # Typechecking should always fill in a type, even 'error'.
    unless @col? && @col.type?
      throw new NotReadyError("column #{@columnId}")
    # Future: Set this when we know it.
    @relationSingular = false
    # Future: Consider rendering _unit with isObject = true specially to save
    # space, e.g., a single column of hollow bullets.  We'd need to figure out
    # how to make this not confusing.
    @width = (@col.type != '_token') + !!@col.isObject
    @leftEdgeSingular = true
    @rightEdgeSingular = true
    # field index -> string or null (class of extra column before this field)
    @extraColClassBefore = []
    @subsections = []
    # @headerHeightBelow and @headerMinHeight refer to the expanded header.
    @headerHeightBelow = 2  # fieldName, type
    @amRootWithSeparateTables =
      options.separateTables && @columnId == rootColumnId
    for sublayout, i in @layoutTree.subtrees
      subsection = new ViewSection(sublayout, @options)
      @subsections.push(subsection)
      nextLeftEdgeSingular =
        subsection.relationSingular && subsection.leftEdgeSingular
      extraColClass =
        if @options.separateTables && @col._id == rootColumnId && i > 0
          'tableSeparator'
        else if @options.sepcols && !@rightEdgeSingular && !nextLeftEdgeSingular
          'separator'
        else
          null
      @extraColClassBefore.push(extraColClass)
      if extraColClass?
        @width++
      @width += subsection.width
      @headerHeightBelow = Math.max(
        @headerHeightBelow, subsection.headerMinHeight)
      @rightEdgeSingular =
        subsection.relationSingular && subsection.rightEdgeSingular
    @headerMinHeight = (@col.isObject && !@amRootWithSeparateTables) + @headerHeightBelow
    if @col.isObject
      # Affects empty sheet when @options.separateTables = true.
      @headerMinHeight = Math.max(@headerMinHeight, 3)

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
      if @col.formula?
        throw new NotReadyError("Cell #{@columnId}:#{JSON.stringify parentCellId}")
      else
        new ViewVlist(parentCellId, 0, null, "internal error: missing family")

  prerenderHlist: (cellId, value) ->
    minHeight = 1
    try
      displayValue = valueToText(liteModel, @col.type, value)
      if typeIsReference(@col.type)
        displayValue = new CellReference(
          {columnId: @col.type, cellId: value}, displayValue)
      error = null
    catch e
      displayValue = null
      error = e.message
    vlists =
      for subsection in @subsections
        subsection.prerenderVlist(cellId)
    minHeight = Math.max(1, (vlist.minHeight for vlist in vlists)...)
    new ViewHlist(cellId, minHeight, displayValue, error, vlists)

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
    markDisplayClassesForType(@col.type)
      
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
      gridObject[0][0].isObjectCell = true
      # For debugging and calling canned transactions from the console.
      gridObject[0][0].fullText = 'Object ID: ' + JSON.stringify(hlist.cellId)
      if @col.type != '_token'
        gridObject[0][0].cssClasses.push('rsKeyedObject')
      gridHorizExtend(grid, gridObject)
    if @col.type != '_token'
      # Value
      gridValue = gridMergedCell(height, 1, hlist.value ? '!')
      if @subsections.length == 0
        gridValue[0][0].cssClasses.push('leaf')
      if hlist.value?
        gridValue[0][0].cssClasses.push(@markDisplayClasses()...)
        if typeIsReference(@col.type)
          gridValue[0][0].cssClasses.push('reference')
      if hlist.error?
        gridValue[0][0].fullText = 'Error converting to text: ' + hlist.error
      gridValue[0][0].qCellId = qCellId
      gridValue[0][0].qFamilyId = qFamilyId
      gridHorizExtend(grid, gridValue)
    # Subsections
    for subsection, i in @subsections
      if @extraColClassBefore[i]?
        extraCells = gridMergedCell(height, 1)
        if @extraColClassBefore[i] == 'separator'
          # Include separator cells in object region highlighting (but for now,
          # not table separator cells for the root object).
          extraCells[0][0].qCellId = qCellId
        gridHorizExtend(grid, extraCells)
      subsectionGrid = subsection.renderVlist(hlist.vlists[i], height)
      gridHorizExtend(grid, subsectionGrid)
    grid

  # As long as siblings are always separated by a separator, we can color just
  # based on depth.
  # If !expanded, then the requested height should always be 3.  Leaves render
  # at height 2 anyway.
  renderHeader: (expanded, height, depth) ->
    # Part that is always the same.
    myColorClass = 'rsHeaderColor' + @colorIndexForDepth(if @col.isObject then depth else depth-1)
    grid = [[], []]  # c.f. renderHlist
    if @col.isObject
      fieldNameCell = new ViewCell(
        '', 1, 1,
        ['rsHeaderFieldNameObject',
         (if @col.type != '_token' then ['rsHeaderFieldNameKeyedObject'] else [])...,
         myColorClass])
      fieldNameCell.columnId = @columnId
      fieldNameCell.isObjectHeader = true
      typeCell = new ViewCell(
        @objectSymbol(), 1, 1,
        ['rsHeaderTypeObject',
         (if @col.type != '_token' then ['rsHeaderTypeKeyedObject'] else [])...,
         'centered', myColorClass])
      typeCell.columnId = @columnId
      typeCell.isObjectHeader = true
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
      typeName = stringifyTypeForSheet(@col.type)
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

    # At this point, height should be at least 3.
    currentHeight = 2  # should always be 2 or height
    # "Corner" here is the upper left corner cell, which actually spans all the
    # way across in some cases (indicated by isFinal).
    makeCorner = (isFinal) =>
      classes = ['rsHeaderCorner']
      unless isFinal
        classes.push('rsHeaderNonfinal')
      classes.push(myColorClass)
      corner = gridMergedCell(height - 2, grid[0].length,
                              @col.objectName ? '', classes)
      corner[0][0].columnId = @columnId
      corner[0][0].isObjectHeader = true
      corner[0][0].kind = 'top'
      gridVertExtend(corner, grid)
      grid = corner
      currentHeight = height

    for subsection, i in @subsections
      if @extraColClassBefore[i]?
        if @extraColClassBefore[i] == 'tableSeparator' && currentHeight == 2
          # Close off the corner for the root object so we can draw a complete
          # table separator column.
          makeCorner(true)
        cssClasses = [@extraColClassBefore[i]]
        unless @extraColClassBefore[i] == 'tableSeparator'
          cssClasses.push(myColorClass)
        gridExtraCol = gridMergedCell(currentHeight, 1, '', cssClasses)
        gridHorizExtend(grid, gridExtraCol)
      subHeight = if expanded then @headerHeightBelow else 3
      subsectionGrid = subsection.renderHeader(expanded, subHeight, depth+1)
      if currentHeight == 2 && subsectionGrid.length > 2
        makeCorner(false)  # may increase currentHeight so next condition holds
      if subsectionGrid.length < currentHeight
        cssClasses = [myColorClass]
        if i < @subsections.length - 1 && !@amRootWithSeparateTables
          cssClasses.push('rsHeaderNonfinal')
        paddingGrid = gridMergedCell(
          currentHeight - subsectionGrid.length, subsection.width,
          '', cssClasses)
        gridVertExtend(paddingGrid, subsectionGrid)
        subsectionGrid = paddingGrid
      gridHorizExtend(grid, subsectionGrid)
    if currentHeight == 2
      makeCorner(true)
    grid

  colorIndexForDepth: (depth) ->
    switch @options.palette
      when 'rainbow' then depth % 6
      when 'alternating' then depth % 2
      else 0


# This may hold a reference to a ViewCell object from an old View.  Weird but
# shouldn't cause any problem and not worth doing differently.
selectedCell = null

class StateEdit

  @PLACEHOLDER = {}
  
  @parseValue: (qFamilyId, text) ->
    if text == @PLACEHOLDER then return "-"  # placeholder. TODO use a special object as placeholder
    type = getColumn(qFamilyId.columnId).type
    if typeIsReference(type)
      #if (m = /^@(\d+)$/.exec(text))
      #  wantRowNum = Number.parseInt(m[1])
      #  for [qCellId, coords] in view.qCellIdToGridCoords.entries()
      #    if qCellId.columnId == type && coords.dataRow == wantRowNum
      #      return qCellId.cellId
      #  throw new Error("Column #{type} contains no cell at row #{wantRowNum}.")
      #else
      if true  # getColumn(type).referenceDisplay?
        # Ignore erroneous families: they do not contain any objects we can match against.
        # Also ignore references that fail to convert to text.
        matchingCells = (cellId for cellId in allCellIdsInColumnIgnoreErrors(type) when (
            try
              text == valueToText(liteModel, type, cellId)
            catch e
              false))
        if matchingCells.length == 1
          return matchingCells[0]
        else if matchingCells.length > 1
          throw new Error('The given reference display string matches ' + matchingCells.length + ' cells.  ' +
                          'Fix the reference display strings to be unique.')  # "or enter the @n notation instead"
        else
          throw new Error('The given reference display string does not match any cells.')
      else
        throw new Error('Malformed cell reference.')
    else if type == '_unit'
      'X'
    else if type == '_token'
      # XXX: Is this OK or do we want the server to generate the token?  For
      # unprivileged users, we probably want the server to generate it, but we
      # may not reuse this code for unprivileged users anyway.
      Random.id()
    else if type == 'text'
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
    if (newValue = @parseValueUi qFamilyId, enteredValue)?
      new FamilyId(qFamilyId).add(newValue, -> $$.call 'notify', callback)

  @modifyCell: (qCellId, enteredValue, callback=->) ->
    cel = new CellId(qCellId)
    fam = cel.family()
    if (newValue = @parseValueUi(fam, enteredValue))?
      cel.value(newValue, -> $$.call 'notify', callback)

  @removeCell: (qCellId, callback=->) ->
    new CellId(qCellId).remove(-> $$.call 'notify', callback)

  @canEdit: (columnId) ->
    col = getColumn(columnId)
    # May as well not let the user try to edit _unit.
    col? && columnIsState(col) && col.type not in ['_token', '_unit']


insertBlankColumn = (parentId, index, isObject, view) ->
  # Obey the restriction on a state column as child of a formula column.
  # Although changeColumnFormula allows this to be bypassed anyway... :(
  formula = if getColumn(parentId).formula? then DUMMY_FORMULA else null
  if isObject && !formula?
    $$.call('insertUnkeyedStateObjectTypeWithField',
            parentId,
            index,
            null,  # objectName
            null,  # fieldName
            DEFAULT_STATE_FIELD_TYPE,  # specifiedType
            view?.id,
            standardServerCallback)
  else
    $$.call('defineColumn',
            parentId,
            index,
            null,  # fieldName
            if formula? then null else DEFAULT_STATE_FIELD_TYPE,  # specifiedType
            isObject,  # isObject
            null,  # objectName
            formula,  # formula
            view?.id,
            standardServerCallback)


headerExpanded = new ReactiveVar(true)
@toggleHeaderExpanded = () ->
  headerExpanded.set(!headerExpanded.get())

class ClientView

  constructor: (@view) ->
    @options =
      # Show type row in header
      showTypes: false
      # Show '+' button to open hierarchical header
      headerExpandable: true
      # 'boring' for grey, 'rainbow' for dazzling colors
      palette: 'alternating'
      # Separator column between every pair of adjacent incomparable columns
      # (except ones that are in separate tables when separateTables is on).
      sepcols: false
      # Show children of the root as separate tables.
      separateTables: true
    @hot = null

    @reload()

  reload: () ->
    @layoutTree = @view?.def()?.layout || View.rootLayout()
    @mainSection = new ViewSection(@layoutTree, @options)

  hotConfig: ->
    thisView = this
    # Display the root column for completeness.  However, it doesn't have a real
    # value.
    hlist = @mainSection.prerenderHlist([], '')
    grid = @mainSection.renderHeader(
      headerExpanded.get(),
      if headerExpanded.get() then @mainSection.headerMinHeight else 3,
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
    gridVertExtend(grid, gridData)

    #gridCaption = []
    if @options.headerExpandable
      if headerHeight > 2
        # This is terrible but it will take ten times as long to do properly...
        # Fix the width so the columns don't move when '+' becomes '-' or vice versa.
        toggleHtml = ("<button class='headerCollapse' onclick='toggleHeaderExpanded();'>" +
                      "#{if headerExpanded.get() then '-' else '+'}</button>")
        grid[0][0].value = toggleHtml
        #gridVertExtend(gridCaption,
        #               gridMergedCell(headerHeight - 2, 1, toggleHtml + ' Obj', ['htBottom', 'rsCaption']))
      #gridCaption.push(
      #  [new ViewCell('Field', 1, 1, ['rsCaption'])],
      #  [new ViewCell('Type', 1, 1, ['rsCaption'])])
    #else
    #  gridVertExtend(gridCaption,
    #                 gridMergedCell(headerHeight - 1, 1, "", ['htBottom', 'rsCaption']))
    #  gridVertExtend(gridCaption,
    #                 gridMergedCell(1, 1, "", ['rsCaption']))

    if !@options.showTypes # HACK: Same
      #gridCaption.pop()
      headerHeight = headerHeight - 1
    #gridVertExtend(gridCaption,
    #               ([new ViewCell("@#{i+1}", 1, 1, ['rsCaption','rsRowNum'])] for i in [0...gridData.length]))
    #gridHorizExtend(gridCaption, grid)
    #grid = gridCaption

    # Resolve cell cross-references.
    # @ notation disabled; relevant code commented out. ~ Matt 2015-11-10
    @qCellIdToGridCoords = new EJSONKeyedMap()
    for rowCells, i in grid
      for cell, j in rowCells
        if cell.qCellId? && cell.isObjectCell
          @qCellIdToGridCoords.set(cell.qCellId, {row: i, col: j})
          ## dataRow is user-facing row number, one-based.
          # dataRow: i - headerHeight + 1
    for row in grid
      for cell in row
        if cell.value instanceof CellReference
          cell.referent = cell.value.qCellId
          cell.display = cell.value.display  # ? '@' + (@qCellIdToGridCoords.get(cell.value.qCellId)?.dataRow || '?')

    @grid = grid

    @colClasses =
      for col in [0...grid[0].length]
        colCls = null
        for row in [0...grid.length]
          for cls in grid[row][col].cssClasses
            if cls in ['rsCaption', 'separator', 'tableSeparator']
              # assert (!colCls? || colCls == cls)
              colCls = cls
        colCls

    {
      data: ((cell.display ? cell.value for cell in row) for row in grid)
      # Future: Fixing the ancestors of the leftmost visible column would be
      # clever, though with carefully designed individual views, we may never
      # need it.  We may also want to fix the header for large data sets.
      #fixedColumnsLeft: 1  # Caption removed
      # Separator columns are 8 pixels wide.  Others use default width.
      colWidths:
        for i in [0...@grid[0].length]  # no way grid can be empty
          switch @colClasses[i]
            when 'tableSeparator' then 20
            when 'separator' then 10
            else undefined
      rowHeights:
        # Specify all the row heights (24 pixels is the Handsontable default),
        # otherwise the fixed clone of the left column sometimes reduced the
        # objectName row to zero height because it wasn't constrained by the
        # content of the real table.  We can look out for any similar glitches.
        if headerExpanded.get()
          for i in [0...@grid.length]
            if i < headerHeight - (2 + @options.showTypes) then 11 else 24
        else
          24 for i in [0...@grid.length]
      cells: (row, col, prop) =>
        cell = @grid[row]?[col]
        if !cell then return {}  # may occur if grid is changing
        adjcol = col+cell.colspan
        classes = if @colClasses[col] == 'tableSeparator' then ['tableSeparator'] else
                  if @colClasses[col] == 'separator' then ['separator'] else
                  if @colClasses[adjcol] == 'separator' then ['incomparable'] else []
        if cell.qCellId? && cell.isObjectCell && (refc = @refId(cell.qCellId))?
          classes.push("ref-#{refc}")
        ancestors = if cell.qCellId? then new CellId(cell.qCellId).ancestors()  \
                    else if cell.qFamilyId? then new FamilyId(cell.qFamilyId).ancestors() \
                    else []
        for ancestor in ancestors
          if (refc = @refId(ancestor.q()))?
            classes.push("parent-#{refc}")
        {
          renderer: if col == 0 && row == 0 then 'html' else 'text'
          className: (cell.cssClasses.concat(classes)).join(' ')
          # Only column header "top", "below", and "type" cells can be edited,
          # for the purpose of changing the objectName, fieldName, and specifiedType respectively.
          readOnly: !(cell.kind in ['top', 'below', 'type'] && cell.columnId != rootColumnId ||
                      cell.qCellId? && !cell.isObjectCell && StateEdit.canEdit(cell.qCellId.columnId) ||
                      cell.qFamilyId? && !cell.isObjectCell && StateEdit.canEdit(cell.qFamilyId.columnId))
        }
      autoColumnSize: {
        # I saw glitches with the asynchronous sizing on the cost sheet.  Rather
        # than investigate, I'm happy to go back to synchronous for now.
        # ~ Matt 2015-11-21
        syncLimit: '100%'
      }
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
          if cell.qCellId? && !cell.isObjectCell
            if newVal
              StateEdit.modifyCell cell.qCellId, newVal
            else
              StateEdit.removeCell cell.qCellId
          else if cell.qFamilyId? && !cell.isObjectCell
            if newVal
              StateEdit.addCell cell.qFamilyId, newVal
        # Don't apply the changes directly; let them come though the Meteor
        # stubs.  This ensures that they get reverted by Meteor if the server
        # call fails.
        return false

      contextMenu: {
        build: (() =>
          c = @getSingleSelectedCell()
          unless c?
            return false
          items = {}

          if (ci = c.columnId)?
            col = getColumn(ci)
            objectName = objectNameWithFallback(col) ? '(unnamed)'
            fieldName = col.fieldName ? '(unnamed)'
            if !col.isObject
              items.promote = {
                name:
                  if columnIsState(col)
                    "Wrap '#{fieldName}' values in objects"
                  else
                    "Generate objects for '#{fieldName}' values"
                callback: () =>
                  Meteor.call('changeColumnIsObject', $$, ci, true,
                              standardServerCallback)
              }
            # If !col.isObject, then the defineColumn (or the first defineColumn
            # of the insertUnkeyedStateObjectTypeWithField) will automatically
            # promote col.
            addFieldItem = {
              name:
                if ci == rootColumnId
                  "Add global value column to sheet"
                else if col.isObject
                  "Add value column to '#{objectName}'"
                else
                  "...and add another value column"
              callback: () =>
                index = col.children.length
                insertBlankColumn(ci, index, false, @view)
            }
            addObjectTypeItem = {
              name:
                if ci == rootColumnId
                  "Add object column to sheet"
                else if col.isObject
                  "Add nested object column to '#{objectName}'"
                else
                  "...and add a nested object column"
              callback: () =>
                index = col.children.length
                insertBlankColumn(ci, index, true, @view)
            }
            if ci == rootColumnId  # order tweak for common case
              items.addObjectTypeItem = addObjectTypeItem
              items.addField = addFieldItem
            else
              items.addField = addFieldItem
              items.addObjectTypeItem = addObjectTypeItem
            if (ci != rootColumnId && col.isObject &&
                col.children.length == (if col.type == '_token' then 1 else 0))
              #parentName = objectNameWithFallback(getColumn(col.parent)) ? '(unnamed)'
              #flattenFieldName =
              #  (if col.type == '_token'
              #    getColumn(col.children[0]).fieldName
              #  else
              #    col.fieldName) ? '(unnamed)'
              items.demote = {
                name:
                  if col.type == '_token'
                    "Flatten out '#{objectName}' objects"
                  else
                    "Remove generated '#{objectName}' objects"
                callback: () =>
                  Meteor.call('changeColumnIsObject', $$, ci, false,
                              standardServerCallback)
              }

            # Don't allow a keyed object column and its key column to be deleted
            # with a single command, since I couldn't find a label for the
            # command that wasn't confusing.  Hopefully it's clear that "Remove
            # generated objects" is the first step toward deleting a keyed
            # object column.
            if (ci != rootColumnId && col.children.length == 0 &&
                (!col.isObject || col.type == '_token'))
              items.delete = {
                name:
                  if col.isObject
                    "Delete '#{objectName}' object column"
                  else
                    "Delete '#{fieldName}' value column"
                callback: () =>
                  @hot.deselectCell() # <- Otherwise changeColumn form gets hosed.
                  Meteor.call('deleteColumn', $$, ci,
                              standardServerCallback)
              }

          else
            if c.referent? && (coords = @qCellIdToGridCoords.get(c.referent))?
              items.jumpToReferent = {
                name: "Jump to object '#{c.display}'"
                callback: () =>
                  @hot.selectCell(coords.row, coords.col, coords.row, coords.col)
              }
            # TODO: Support adding values too.  We just have to figure out the
            # flow to temporarily create a cell for the new value and then
            # remove it again if the user doesn't end up adding a value.
            if c.qFamilyId? && columnIsState(col = getColumn(c.qFamilyId.columnId)) && col.isObject
              objectName = objectNameWithFallback(col) ? '(unnamed)'
              items.add = {
                name: "Add '#{objectName}' object here"
                callback: () =>
                  StateEdit.addCell(c.qFamilyId, standardServerCallback)
              }
            if c.qCellId? && columnIsState(col = getColumn(c.qCellId.columnId))
              items.delete = {
                # This currently gives 'Delete object' for the key of a keyed object
                # (deprecated).  If we wanted that case to say 'Delete value', we
                # would test c.isObjectCell instead.
                name: if col.isObject then 'Delete object' else 'Delete value'
                callback: () =>
                  StateEdit.removeCell(c.qCellId, standardServerCallback)
              }

          haveSomething = false
          for k, v of items
            haveSomething = true
          unless haveSomething
            items.nothing = {
              name: 'No actions available here'
              disabled: () -> true
            }

          {items: items})  # build callback
      }  # contextMenu
    }  # Handsontable config object

  hotCreate: (domElement) ->
    cfg = @hotConfig()
    @hot = new Handsontable(domElement, cfg)
    $(domElement).addClass("pal-#{@options.palette}")
    if @options.showTypes then $(domElement).addClass('showTypes')
    # Monkey patch: Don't let the user merge or unmerge cells.
    @hot.mergeCells.mergeOrUnmergeSelection = (cellRange) ->

  hotReconfig: () ->
    cfg = @hotConfig()
    @hot.updateSettings {colWidths: cfg.colWidths, rowHeights: cfg.rowHeights, mergeCells: cfg.mergeCells}
    @hot.loadData cfg.data
    #@hot.render()

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
    ActionBar.fullTextToShow.set(selectedCell?.fullText)
    @highlightReferent(selectedCell?.referent)
    @highlightObject(if selectedCell?.isObjectCell then selectedCell.qCellId else null)
    # _id: Hacks to get the #each to clear the forms when the cell changes.
    ActionBar.addStateCellArgs.set(
      if (qf = selectedCell?.qFamilyId)? && columnIsState(col = getColumn(qf.columnId))
        [{
          _id: EJSON.stringify(qf)
          qFamilyId: qf
          canAddValue: col.type not in ['_token', '_unit'] && !selectedCell.isObjectCell
          # A token column has only the object UI-column, though we don't set
          # isObject on family padding cells.  So don't check it.
          canAddToken: col.type == '_token'
          # Adding a duplicate value has no effect, but disallow it as a
          # hint to the user.  !selectedCell.isObjectCell is in principle a
          # requirement, though it ends up being redundant because the only way
          # to select an object cell is to already have a unit value present.
          canAddUnit: (col.type == '_unit' && !selectedCell.isObjectCell &&
                       !Cells.findOne({column: qf.columnId, key: qf.cellId})?.values?.length)
        }]
      else
        []
    )
    ActionBar.changeColumnArgs.set(
      if selectedCell? &&
         (ci = selectedCell.columnId)? && ci != rootColumnId
        [{_id: ci, columnId: ci, onObjectHeader: selectedCell.isObjectHeader}]
      else
        []
    )

  onKeyDown: (event) ->
    if event.altKey && event.metaKey
      Handsontable.Dom.stopImmediatePropagation(event)
    else if !event.altKey && !event.ctrlKey && !event.metaKey 
      if event.which == 13    # Enter
        selectedCell = @getSingleSelectedCell()
        if (qf = selectedCell?.qFamilyId)? && columnIsState(col = getColumn(qf.columnId))
          if col.type == '_token'
            StateEdit.addCell qf, '*'
      else if event.which == 46 || event.which == 8   # Delete / Backspace
        selectedCell = @getSingleSelectedCell()
        if (qc = selectedCell?.qCellId)? && columnIsState(col = getColumn(qc.columnId))
          if col.type == '_token'
            StateEdit.removeCell qc
    else if event.ctrlKey && !event.altKey && !event.metaKey
      if event.which == 13    # Enter
        selectedCell = @getSingleSelectedCell()
        if (qf = selectedCell?.qFamilyId)? && columnIsState(col = getColumn(qf.columnId))
          StateEdit.addCell qf, (if col.type == '_token' then '*' else StateEdit.PLACEHOLDER)
          Handsontable.Dom.stopImmediatePropagation(event)
    else if event.altKey && !event.ctrlKey && !event.metaKey
      # Use Alt + Left/Right to reorder columns inside parent
      #     Alt + Up/Down to make column into object/value
      if event.which == 37 || event.which == 39 || event.which == 38 || event.which == 40
        Handsontable.Dom.stopImmediatePropagation(event)
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

    ActionBar.keydownHook? event
          
  
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
                                     selectedCell.isObjectCell == c.isObjectCell)) ||
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
  ActionBar.isLoading.set(false)

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
    window.why = null


Template.Spreadsheet.rendered = ->
  sheet = @data?.sheet || ''
  viewId = @data?.viewId
  # $('body').addClass("present")   # uncomment for presentation mode (read from query string?)
  if sheet then document.title = sheet
  Relsheets.open(sheet)
  Tracker.autorun(guarded -> rebuildView viewId)

Template.Spreadsheet.helpers({
  # TODO: Find a less hacky way to make this happen? ~ Matt 2015-10-01
  actionBarClass: -> if ActionBar.isExpanded() then 'actionBarExpanded' else ''
})


$ ->
  exported {ClientView, StateEdit, rebuildView, guarded}
