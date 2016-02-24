// Grid utilities


class ViewCell {
  public qFamilyId;
  public qCellId;
  public columnId;
  public isObject;
  public kind;
  public fullText;
  public isObjectHeader;

  constructor(public value : any = null, public rowspan : any = 1, public colspan : any = 1, public cssClasses : any = []) {
    this.qFamilyId = null;
    this.qCellId = null;
    this.columnId = null;
    // Use in combination with columnId or qCellId to distinguish key and object
    // (bullet/chevron) columns in the UI.
    this.isObject = false;
    this.kind = null;
    this.fullText = null;
  }
}
exported({
  ViewCell: ViewCell
});

// Mutate "orig" by adding "extension" at the bottom.
// This would be a good place to add some assertions...
this.gridVertExtend = (orig, extension) => {
  for (let row of extension) {
    orig.push(row);
  }
};

// Mutate "orig" by adding "extension" at the right.
this.gridHorizExtend = (orig, extension) => {
  for (let i = 0; i < orig.length; i++) {
    for (let cell of extension[i]) {
      orig[i].push(cell);
    }
  }
};

// Return a grid consisting of one "height x width" merged cell and enough dummy
// 1x1 cells.  You can mutate the upper-left cell as desired.
this.gridMergedCell = (height, width, value : any = "", cssClasses : any = []) => {
  let grid = _.range(0, height).map((i) => _.range(0, width).map((j) => new ViewCell(null)));
  grid[0][0].rowspan = height;
  grid[0][0].colspan = width;
  grid[0][0].value = value;
  grid[0][0].cssClasses = cssClasses;
  return grid;
};

this.gridCell = (grid, row, col) => {
  for (let i = 0; i <= row; i++) {
    for (let j = 0; j <= col; j++) {
      let cell = grid[i][j];
      if (i + cell.rowspan > row && j + cell.colspan > col) {
        return cell;
      }
    }
  }
  throw new Error(`cell (${row},${col}) does not exist in grid`);
};

this.gridBottomRow = (grid) => {
  var _results;
  if (grid.length === 0) {
    return [];
  } else {
    let i = grid.length - 1;
    let j = 0;
    _results = [];
    while (j < grid[i].length) {
      let cell = gridCell(grid, i, j);
      j += cell.colspan;
      _results.push(cell);
    }
    return _results;
  }
};
