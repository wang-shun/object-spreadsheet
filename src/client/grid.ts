// Grid utilities


namespace Objsheets {

  // Object that can be used as ViewCell.value or ViewHlist.value to defer the
  // resolution of the target cell ID to a row number.
  export class CellReference {
    constructor(public qCellId: QCellId, public display: string) {}
  }

  export class ViewCell {
    public qCellId: QCellIdWithSpares;
    // Set for header only.
    // (TODO: Rename to headerColumnId once code is typed?)
    public columnId: ColumnIdWithSpares;
    public isObject: boolean;
    public kind: fixmeAny;
    public fullText: string;
    public isObjectHeader: boolean;
    public isObjectCell: boolean;
    // Used for object region highlighting.
    public ancestorQCellId: QCellIdWithSpares;
    public isPlaceholder: boolean;

    // XXX: We could probably replace these with accessors.
    public display: string;
    public referent: QCellId;

    constructor(public value: string | CellReference = null, public rowspan = 1, public colspan = 1, public cssClasses: string[] = []) {
      this.qCellId = null;
      this.columnId = null;
      // Use in combination with columnId or qCellId to distinguish key and object
      // (bullet/chevron) columns in the UI.
      this.isObject = false;
      this.kind = null;
      this.fullText = null;
    }
  }

  export type ViewGrid = ViewCell[][];

  // Mutate "orig" by adding "extension" at the bottom.
  // This would be a good place to add some assertions...
  export function gridVertExtend(orig: ViewGrid, extension: ViewGrid): void {
    for (let row of extension) {
      orig.push(row);
    }
  }

  // Mutate "orig" by adding "extension" at the right.
  export function gridHorizExtend(orig: ViewGrid, extension: ViewGrid): void {
    for (let i = 0; i < orig.length; i++) {
      for (let cell of extension[i]) {
        orig[i].push(cell);
      }
    }
  }

  // Return a grid consisting of one "height x width" merged cell and enough dummy
  // 1x1 cells.  You can mutate the upper-left cell as desired.
  export function gridMergedCell(height: number, width: number,
      value: string | CellReference = "", cssClasses: string[] = []): ViewGrid {
    let grid = _.range(0, height).map((i) => _.range(0, width).map((j) => new ViewCell(null)));
    if (width > 0 && height > 0) {
      grid[0][0].rowspan = height;
      grid[0][0].colspan = width;
      grid[0][0].value = value;
      grid[0][0].cssClasses = cssClasses;
    }
    return grid;
  }

  export function gridCell(grid: ViewGrid, row: number, col: number): ViewCell {
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

  export function gridBottomRow(grid: ViewGrid): ViewCell[] {
    if (grid.length === 0) {
      return [];
    } else {
      let i = grid.length - 1;
      let j = 0;
      let _results: ViewCell[] = [];
      while (j < grid[i].length) {
        let cell = gridCell(grid, i, j);
        j += cell.colspan;
        _results.push(cell);
      }
      return _results;
    }
  }

}
