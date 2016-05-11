// Grid utilities

namespace Objsheets {

  export class ViewCell {
    public qCellId: fixmeAny;
    public columnId: fixmeAny;
    public isObject: fixmeAny;
    public kind: fixmeAny;
    public fullText: fixmeAny;
    public isObjectHeader: fixmeAny;
    public isObjectCell: fixmeAny;
    public ancestorQCellId: QCellId;
    // If set to a state column, then data can be added to this cell, and
    // any missing ancestors will be automatically created up to
    // ancestorQCellId.
    public addColumnId : ColumnId;
    public isPlaceholder: boolean;
    // For spare columns: set to object column id where the new column should
    // be added as a child. 
    // Notice that only one of addColumnId, ancestorType may be non-null on a given cell
    public ancestorType: ColumnId;

    constructor(public value: fixmeAny = null, public rowspan: fixmeAny = 1, public colspan: fixmeAny = 1, public cssClasses: fixmeAny = []) {
      this.qCellId = null;
      this.columnId = null;
      // Use in combination with columnId or qCellId to distinguish key and object
      // (bullet/disc) columns in the UI.
      this.isObject = false;
      this.kind = null;
      this.fullText = null;
    }
  }

  // Mutate "orig" by adding "extension" at the bottom.
  // This would be a good place to add some assertions...
  export function gridVertExtend(orig: fixmeAny, extension: fixmeAny[][]) {
    if (orig.length > 0) assert(() => extension.every((x) => x.length == orig[0].length))
    for (let row of extension) {
      orig.push(row);
    }
  }

  // Mutate "orig" by adding "extension" at the right.
  export function gridHorizExtend(orig: fixmeAny, extension: fixmeAny) {
    for (let i = 0; i < orig.length; i++) {
      for (let cell of extension[i]) {
        orig[i].push(cell);
      }
    }
  }
  
  export function gridVertStretch(orig: ViewCell[][], height: number) {
    assert(() => 0 < orig.length && orig.length <= height);
    if (orig.length < height) {
      var width = orig[0].length;
      var deltaHeight = height - orig.length;
      gridBottomRow(orig).forEach((cell) => cell.rowspan += deltaHeight);
      for (let i = orig.length; i < height; i++) {
        orig.push(_.range(0, width).map(() => new ViewCell(null)));
      }
    }
  }

  // Return a grid consisting of one "height x width" merged cell and enough dummy
  // 1x1 cells.  You can mutate the upper-left cell as desired.
  export function gridMergedCell(height: fixmeAny, width: fixmeAny, value: fixmeAny = "", cssClasses: fixmeAny = []) {
    // assert that extension has compatible width
    let grid = _.range(0, height).map((i) => _.range(0, width).map((j) => new ViewCell(null)));
    if (width > 0) {
      grid[0][0].rowspan = height;
      grid[0][0].colspan = width;
      grid[0][0].value = value;
      grid[0][0].cssClasses = cssClasses;
    }
    return grid;
  }

  export function gridMatrix(height: number, width: number, value: any = "", cssClasses: string[] = [], attrs: {} = {}): ViewCell[][] {
    return _.range(0, height).map((i) => _.range(0, width).map((j) => _.extend(new ViewCell(value, 1, 1, cssClasses), attrs)));
  }

  export function gridGetCell(grid: fixmeAny, row: fixmeAny, col: fixmeAny) {
    for (let i = 0; i <= row; i++) {
      for (let j = 0; j <= col; j++) {
        let cell = grid[i][j];
        if (i + cell.rowspan > row && j + cell.colspan > col) {
          return cell;
        }
      }
    }
    throw new Error(`cell (${row},${col}) does not exist in grid`);
  }

  export function gridBottomRow(grid: ViewCell[][]) {
    var _results: ViewCell[];
    if (grid.length === 0) {
      return [];
    } else {
      let i = grid.length - 1;
      let j = 0;
      _results = [];
      while (j < grid[i].length) {
        let cell = gridGetCell(grid, i, j);
        j += cell.colspan;
        _results.push(cell);
      }
      return _results;
    }
  }

}
