# Grid utilities

class @ViewCell
  constructor: (@value = null, @rowspan = 1, @colspan = 1, @cssClasses = []) ->
    @qFamilyId = null
    @qCellId = null
    @columnId = null
    # Use in combination with columnId or qCellId to distinguish key and object
    # (bullet/chevron) columns in the UI.
    @isObject = false
    @kind = null
    @fullText = null

# Mutate "orig" by adding "extension" at the bottom.
# This would be a good place to add some assertions...
@gridVertExtend = (orig, extension) ->
  for row in extension
    orig.push(row)
  return

# Mutate "orig" by adding "extension" at the right.
@gridHorizExtend = (orig, extension) ->
  for i in [0...orig.length]
    for cell in extension[i]
      orig[i].push(cell)
  return

# Return a grid consisting of one "height x width" merged cell and enough dummy
# 1x1 cells.  You can mutate the upper-left cell as desired.
@gridMergedCell = (height, width, value = '', cssClasses = []) ->
  grid =
    for i in [0...height]
      for j in [0...width]
        new ViewCell(null)
  grid[0][0].rowspan = height
  grid[0][0].colspan = width
  grid[0][0].value = value
  grid[0][0].cssClasses = cssClasses
  grid

@gridCell = (grid, row, col) ->
  for i in [0..row]
    for j in [0..col]
      cell = grid[i][j]
      if i + cell.rowspan > row && j + cell.colspan > col
        return cell
  throw new Error("cell (#{row},#{col}) does not exist in grid")

@gridBottomRow = (grid) ->
  if grid.length == 0
    []
  else
    i = grid.length - 1
    j = 0
    while j < grid[i].length
      cell = gridCell(grid, i, j)
      j += cell.colspan
      cell
