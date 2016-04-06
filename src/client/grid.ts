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
    public ancestorQCellId: fixmeAny;
    // If set to a state column, then data can be added to this cell, and
    // any missing ancestors will be automatically created up to
    // ancestorQCellId.
    public addColumnId : string;
    public isPlaceholder: fixmeAny;

    constructor(public value: fixmeAny = null, public rowspan: fixmeAny = 1, public colspan: fixmeAny = 1, public cssClasses: fixmeAny = []) {
      this.qCellId = null;
      this.columnId = null;
      // Use in combination with columnId or qCellId to distinguish key and object
      // (bullet/chevron) columns in the UI.
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

  // Return a grid consisting of one "height x width" merged cell and enough dummy
  // 1x1 cells.  You can mutate the upper-left cell as desired.
  export function gridMergedCell(height: fixmeAny, width: fixmeAny, value: fixmeAny = "", cssClasses: fixmeAny = []) {
    let grid = _.range(0, height).map((i) => _.range(0, width).map((j) => new ViewCell(null)));
    if (width > 0) {
      grid[0][0].rowspan = height;
      grid[0][0].colspan = width;
      grid[0][0].value = value;
      grid[0][0].cssClasses = cssClasses;
    }
    return grid;
  }

  export function gridCell(grid: fixmeAny, row: fixmeAny, col: fixmeAny) {
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

  export function gridBottomRow(grid: fixmeAny) {
    var _results: fixmeAny;
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
  }

}
