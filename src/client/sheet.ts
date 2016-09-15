namespace Objsheets {

  Router.route("/:sheet", function(this: fixmeAny) {
    this.render("Spreadsheet", {
      data: {
        sheet: this.params.sheet
      }
    });
  });
  Router.route("/:sheet/views/:_id", function(this: fixmeAny) {
    this.render("Spreadsheet", {
      data: {
        sheet: this.params.sheet,
        viewId: this.params._id
      }
    });
  });

  class NotReadyError_ {
    constructor(public message: fixmeAny) {}
  }
  let NotReadyError = Meteor.makeErrorType("NotReadyError", NotReadyError_);

  // Object that can be used as ViewCell.value or ViewHlist.value to defer the
  // resolution of the target cell ID to a row number.  I'm a terrible person for
  // taking advantage of heterogeneous fields in JavaScript... ~ Matt
  export class CellReference {
    constructor(public qCellId: fixmeAny, public display: fixmeAny) {}
  }

  export function stringifyTypeForSheet(type: fixmeAny) {
    let col: fixmeAny, name: fixmeAny;
    if (type === "_unit") {
      return "X";
    } else if (!typeIsReference(type)) {
      return type;
    } else if (typeIsReference(type) && ((col = Columns.findOne(type)) != null) && ((name = objectNameWithFallback(col)) != null)) {
      // XXX May be ambiguous.
      return name;
    } else {
      return "<?>";
    }
  }

  export function markDisplayClassesForType(type: fixmeAny) {
    return type === "_unit" ? ["centered"] : [];
  }

  class ViewVlist {
    constructor(public parentCellId: fixmeAny, public minHeight: fixmeAny, public hlists: fixmeAny, public numPlaceholders?: fixmeAny, public error?: fixmeAny) {}
  }

  class ViewHlist {
    constructor(public cellId: fixmeAny, public minHeight: fixmeAny, public value: fixmeAny, public error: fixmeAny, public vlists: fixmeAny) {}
  }

  class ViewSection {
    public columnId: fixmeAny;
    public col: fixmeAny;
    public relationSingular: fixmeAny;
    public showBullets: fixmeAny;
    public width: fixmeAny;
    public leftEdgeSingular: fixmeAny;
    public rightEdgeSingular: fixmeAny;
    public haveTableSeparatorBefore: boolean[];
    public subsections: fixmeAny;
    public headerHeightBelow: fixmeAny;
    public headerMinHeight: fixmeAny;

    constructor(public layoutTree: fixmeAny, public options: fixmeAny = {}) {
      this.columnId = this.layoutTree.root;
      this.col = getColumn(this.columnId);
      // Typechecking should always fill in a type, even 'error'.
      if (!((this.col != null) && (this.col.type != null))) {
        throw new NotReadyError(`column ${this.columnId}`);
      }
      // Future: Set this when we know it.
      this.relationSingular = false;
      // Future: Consider rendering _unit with isObject = true specially to save
      // space, e.g., a single column of hollow bullets.  We'd need to figure out
      // how to make this not confusing.
      this.showBullets = this.col.isObject &&
        (this.options.showBullets || this.layoutTree.subtrees.length == 0);
      this.width = (this.col.type !== "_token" ? 1 : 0) + (this.showBullets ? 1 : 0);
      this.leftEdgeSingular = true;
      this.rightEdgeSingular = true;
      // field index -> string or null (class of extra column before this field)
      this.haveTableSeparatorBefore = [];
      this.subsections = [];
      // @headerHeightBelow and @headerMinHeight refer to the expanded header.
      this.headerHeightBelow = 2;  // fieldName, type
      this.layoutTree.subtrees.forEach((sublayout: fixmeAny, i: fixmeAny) => {
        let subsection = new ViewSection(sublayout, this.options);
        this.subsections.push(subsection);
        let nextLeftEdgeSingular = subsection.relationSingular && subsection.leftEdgeSingular;
        let htsb = this.col._id === rootColumnId && i > 0;
        this.haveTableSeparatorBefore.push(htsb);
        if (htsb) {
          this.width++;
        }
        this.width += subsection.width;
        this.headerHeightBelow = Math.max(this.headerHeightBelow, subsection.headerMinHeight);
        this.rightEdgeSingular = subsection.relationSingular && subsection.rightEdgeSingular;
      });
      this.headerMinHeight = (this.col.isObject && this.columnId !== rootColumnId) + this.headerHeightBelow;
      if (this.col.isObject) {
        // Affects empty sheet.
        this.headerMinHeight = Math.max(this.headerMinHeight, 3);
      }
    }

    public prerenderVlist(parentCellId: fixmeAny) {
      let ce = Cells.findOne({
        column: this.columnId,
        key: parentCellId
      });
      if ((ce != null ? ce.values : null) != null) {
        let hlists = ce.values.map((value: fixmeAny) => this.prerenderHlist(cellIdChild(parentCellId, value), value));
        let minHeight = 0;
        for (let hlist of hlists) {
          minHeight += hlist.minHeight;
        }
        // Don't add any placeholders automatically: it's looking ridiculous.  Once
        // we know which columns are plural, we can reconsider adding extra rows.
        let numPlaceholders = fallback(ce.numPlaceholders, 0);
        minHeight += numPlaceholders;
        return new ViewVlist(parentCellId, minHeight, hlists, numPlaceholders, null);
      } else if ((ce != null ? ce.error : null) != null) {
        return new ViewVlist(parentCellId, 1, null, null, ce.error);
      } else {
        if (this.col.formula != null) {
          throw new NotReadyError(`Cell ${this.columnId}:${JSON.stringify(parentCellId)}`);
        } else {
          // Ignore missing state families (treat as if it were empty)
          return new ViewVlist(parentCellId, 0, [], 0);  //null, null, "internal error: missing family")
        }
      }
    }

    public prerenderHlist(cellId: fixmeAny, value: fixmeAny) {
      let minHeight = 1, displayValue: fixmeAny, error: fixmeAny;
      try {
        displayValue = valueToText(liteModel, this.col.type, value);
        if (typeIsReference(this.col.type)) {
          displayValue = new CellReference({
            columnId: this.col.type,
            cellId: value
          }, displayValue);
        }
        error = null;
      } catch (e) {
        displayValue = null;
        error = e.message;
      }
      let vlists = this.subsections.map((subsection: ViewSection) => subsection.prerenderVlist(cellId));
      minHeight = Math.max.apply(Math, [1].concat(vlists.map((vlist: fixmeAny) => vlist.minHeight)));
      return new ViewHlist(cellId, minHeight, displayValue, error, vlists);
    }

    public renderVlist(vlist: fixmeAny, height: fixmeAny) {
      let qFamilyId = {
        columnId: this.columnId,
        cellId: vlist.parentCellId
      };
      let ancestorQCellId = {
        columnId: this.col.parent,
        cellId: vlist.parentCellId
      };
      let grid: fixmeAny;
      if (vlist.hlists != null) {
        grid = [];
        for (let hlist of vlist.hlists) {
          gridVertExtend(grid, this.renderHlist(hlist, ancestorQCellId, hlist.minHeight));
        }
        for (let cell of gridBottomRow(grid)) {
          cell.cssClasses.push("vlast");
        }
        for (let i = 0; i < vlist.numPlaceholders; i++) {
          // This should occur only in value columns, so gridPlaceholder should be 1x1.
          let gridPlaceholder = this.renderHlist(null, ancestorQCellId, 1);
          gridPlaceholder[0][0].isPlaceholder = true;
          gridVertExtend(grid, gridPlaceholder);
        }
        if (grid.length < height) {
          if (grid.length === 1) {
            // Make this row span 'height' rows
            for (let i = 1; i < height; i++) {
              grid.push(_.range(0, this.width).map((j) => new ViewCell()));
            }
            for (let cell of grid[0]) {
              cell.rowspan = height;
            }
          } else {
            while (grid.length < height)
              gridVertExtend(grid, this.renderHlist(null, ancestorQCellId, 1));
          }
        }
      } else {
        grid = gridMergedCell(height, this.width, "error", ["dataError"]);
        if (this.width > 0) {
          grid[0][0].fullText = "Error: " + vlist.error;
        }
      }
      return grid;
    }

    public markDisplayClasses() {
      return markDisplayClassesForType(this.col.type);
    }

    // Only applicable if @col.isObject.

    public objectSymbol() {
      return this.col._id === rootColumnId ? "" : this.col.type === "_token" ? "•" : "◦";
    }

    // typeColors: EJSONKeyedMap<string, int>

    public findTypesToColor(typeColors: fixmeAny) {
      if (typeIsReference(this.col.type)) {
        typeColors.set(this.col.type, "TBD");
      }
      for (let subsection of this.subsections) {
        subsection.findTypesToColor(typeColors);
      }
    }

    public assignTypeColors(nextColor: fixmeAny, typeColors: fixmeAny) {
      if (typeColors.get(this.columnId) === "TBD") {
        typeColors.set(this.columnId, nextColor++);
      }
      for (let subsection of this.subsections) {
        nextColor = subsection.assignTypeColors(nextColor, typeColors);
      }
      return nextColor;
    }

    // Can be called with hlist == null for an empty row.
    public renderHlist(hlist: fixmeAny, ancestorQCellId: fixmeAny, height: fixmeAny) {
      let grid = _.range(0, height).map((i) => []);
      let qCellId = (hlist == null) ? null : {
        columnId: this.columnId,
        cellId: hlist.cellId
      };
      if (this.showBullets) {
        // Object
        let gridObject = gridMergedCell(height, 1,
          hlist == null ? "" : this.objectSymbol(),
          [hlist == null ? "dataPadding" : "centered"]);
        gridObject[0][0].ancestorQCellId = ancestorQCellId;
        gridObject[0][0].addColumnId = this.columnId;
        gridObject[0][0].qCellId = qCellId;
        gridObject[0][0].isObjectCell = true;
        // For debugging and calling canned transactions from the console.
        //gridObject[0][0].fullText = 'Object ID: ' + JSON.stringify(hlist.cellId)
        if (this.col.type !== "_token") {
          gridObject[0][0].cssClasses.push("rsKeyedObject");
        }
        gridHorizExtend(grid, gridObject);
      }
      if (this.col.type !== "_token") {
        // Value
        let gridValue = gridMergedCell(height, 1,
          hlist == null ? "" : fallback(hlist.value, "<?>"),
          hlist == null ? ["dataPadding"] : []);
        gridValue[0][0].ancestorQCellId = ancestorQCellId;
        gridValue[0][0].addColumnId = this.columnId;
        gridValue[0][0].qCellId = qCellId;
        if (hlist != null) {
          if (this.subsections.length === 0) {
            gridValue[0][0].cssClasses.push("leaf");
          }
          if (hlist.value != null) {
            for (let displayClass of this.markDisplayClasses()) {
              gridValue[0][0].cssClasses.push(displayClass);
            }
            if (typeIsReference(this.col.type)) {
              gridValue[0][0].cssClasses.push("reference");
            }
          }
          if (hlist.error != null) {
            gridValue[0][0].cssClasses.push("dataError");
            gridValue[0][0].fullText = "Error converting to text: " + hlist.error;
          }
        }
        gridHorizExtend(grid, gridValue);
      }
      // Subsections
      this.subsections.forEach((subsection: fixmeAny, i: fixmeAny) => {
        if (this.haveTableSeparatorBefore[i]) {
          let extraCells = gridMergedCell(height, 1, "", ["tableSeparator"]);
          gridHorizExtend(grid, extraCells);
        }
        let subsectionGrid =
          (hlist == null)
            ? subsection.renderHlist(null, ancestorQCellId, height)
            : subsection.renderVlist(hlist.vlists[i], height);
        gridHorizExtend(grid, subsectionGrid);
      });
      return grid;
    }

    // If !expanded, then the requested height should always be 3.  Leaves render
    // at height 2 anyway.

    public renderHeader(expanded: fixmeAny, height: fixmeAny, depth: fixmeAny, typeColors: fixmeAny) {
      // Part that is always the same.
      let fieldMatchIdx: fixmeAny, matchIdx: fixmeAny;
      let myDepthClass = "rsHeaderDepth" + this.colorIndexForDepth(this.col.isObject ? depth : depth - 1);
      // Currently matching-colored header cells don't depend on depth.  You could
      // argue we should generate two classes and let the CSS deal with it.
      let myColorClass = (matchIdx = typeColors.get(this.columnId)) != null ? "rsHeaderMatch" + this.colorIndexForMatch(matchIdx) : myDepthClass;
      let grid: fixmeAny = [[], []];  // c.f. renderHlist
      if (this.showBullets) {
        let fieldNameCell = new ViewCell("", 1, 1, ["rsHeaderFieldNameObject"].concat((this.col.type !== "_token" ? ["rsHeaderFieldNameKeyedObject"] : []), [myColorClass]));
        fieldNameCell.columnId = this.columnId;
        fieldNameCell.isObjectHeader = true;
        let typeCell = new ViewCell(this.objectSymbol(), 1, 1, ["rsHeaderTypeObject"].concat((this.col.type !== "_token" ? ["rsHeaderTypeKeyedObject"] : []), ["centered"], [myColorClass]));
        typeCell.columnId = this.columnId;
        typeCell.isObjectHeader = true;
        if (this.col.type === "_token") {
          // There is no value UI-column, so certain functionality that would
          // normally be on the value UI-column is on the object UI-column instead.
          fieldNameCell.kind = "tokenObject-below";
          typeCell.kind = "tokenObject-type";
          //typeCell.fullText = 'Column ID ' + @columnId + ' (token)'
        } else {
          fieldNameCell.kind = "keyedObject-below";
          typeCell.kind = "keyedObject-type";
        }
        gridHorizExtend(grid, [[fieldNameCell], [typeCell]]);
      }
      if (this.col.type !== "_token") {
        let myFieldColorClass = (fieldMatchIdx = typeColors.get(this.col.type)) != null ? "rsHeaderMatch" + this.colorIndexForMatch(fieldMatchIdx) : myDepthClass;
        let fieldNameCell = new ViewCell(fallback(this.col.fieldName, ""), 1, 1, [(this.col.isObject ? "rsHeaderFieldNameKey" : "rsHeaderFieldNameLeaf"), myFieldColorClass]);
        fieldNameCell.columnId = this.columnId;
        fieldNameCell.kind = "below";
        let typeName = stringifyTypeForSheet(this.col.type);
        // The type is essential to interpret values in the column.  The rest of
        // the attributes are no more important than the formula itself, which we
        // currently show only in the action bar, so don't show them here.
        let typeCell = new ViewCell(typeName, 1, 1, [(this.col.isObject ? "rsHeaderTypeKey" : "rsHeaderTypeLeaf"), myFieldColorClass].concat(this.markDisplayClasses()));
        typeCell.columnId = this.columnId;
        typeCell.kind = "type";
        gridHorizExtend(grid, [[fieldNameCell], [typeCell]]);
      }

      if (!this.col.isObject) {
        return grid;
      }

      // At this point, height should be at least 3.
      let currentHeight = 2;  // should always be 2 or height
      // "Corner" here is the upper left corner cell, which actually spans all the
      // way across in some cases (indicated by isFinal).
      let makeCorner = (isFinal: fixmeAny) => {
        let classes = ["rsHeaderCorner"];
        if (!isFinal) {
          classes.push("rsHeaderNonfinal");
        }
        classes.push(myColorClass);
        let corner = gridMergedCell(height - 2, grid[0].length, fallback(this.col.objectName, ""), classes);
        if (grid[0].length > 0) {
          corner[0][0].columnId = this.columnId;
          corner[0][0].isObjectHeader = true;
          corner[0][0].kind = "top";
        }
        gridVertExtend(corner, grid);
        grid = corner;
        currentHeight = height;
      };

      this.subsections.forEach((subsection: fixmeAny, i: fixmeAny) => {
        if (this.haveTableSeparatorBefore[i]) {
          if (currentHeight === 2) {
            // Close off the corner for the root object so we can draw a complete
            // table separator column.
            makeCorner(true);
          }
          let gridExtraCol = gridMergedCell(currentHeight, 1, "", ["tableSeparator"]);
          gridHorizExtend(grid, gridExtraCol);
        }
        let subHeight = expanded ? this.headerHeightBelow : 3;
        let subsectionGrid = subsection.renderHeader(expanded, subHeight, depth + 1, typeColors);
        if (currentHeight === 2 && subsectionGrid.length > 2) {
          makeCorner(false);  // may increase currentHeight so next condition holds
        }
        if (subsectionGrid.length < currentHeight) {
          let cssClasses = [myColorClass];
          // If this.columnId === rootColumnId, then the padding cell should
          // have a right border because there will be a table separator column.
          if (i < this.subsections.length - 1 && this.columnId !== rootColumnId) {
            cssClasses.push("rsHeaderNonfinal");
          }
          let paddingGrid = gridMergedCell(currentHeight - subsectionGrid.length, subsection.width, "", cssClasses);
          gridVertExtend(paddingGrid, subsectionGrid);
          subsectionGrid = paddingGrid;
        }
        gridHorizExtend(grid, subsectionGrid);
      });
      if (currentHeight === 2) {
        makeCorner(true);
      }
      return grid;
    }

    public colorIndexForDepth(depth: fixmeAny) {
      switch (this.options.palette) {
        case "rainbow":
          return depth % 6;
        case "alternating":
          return depth % 2;
        default:
          return 0;
      }
    }

    public colorIndexForMatch(matchIdx: fixmeAny) {
      // The cost example uses 8 so it repeats colors.  If we use more different
      // colors, they will start to look similar; would it still be worth doing
      // compared to repeating colors?
      switch (this.options.palette) {
        case "alternating":
          return matchIdx % 5;
        default:
          return 0;
      }
    }
  }

  // This may hold a reference to a ViewCell object from an old View.  Weird but
  // shouldn't cause any problem and not worth doing differently.
  let selectedCell: fixmeAny = null;
  type SelectionPredicate = (c: ViewCell) => boolean;
  let pendingSelectionPredicate: SelectionPredicate = null;
  function postSelectionPredicate(predicate: SelectionPredicate) {
    if (sheetView != null && sheetView.selectMatchingCell(predicate))
      pendingSelectionPredicate = null;
    else
      pendingSelectionPredicate = predicate;
  }

  export class StateEdit {
    public static parseValue(columnId: fixmeAny, text: fixmeAny) {
      let type = getColumn(columnId).type;
      //if typeIsReference(type)
      //  if (m = /^@(\d+)$/.exec(text))
      //    wantRowNum = Number.parseInt(m[1])
      //    for [qCellId, coords] in view.qCellIdToGridCoords.entries()
      //      if qCellId.columnId == type && coords.dataRow == wantRowNum
      //        return qCellId.cellId
      //    throw new Error("Column #{type} contains no cell at row #{wantRowNum}.")
      return parseValue(type, text);
    }

    public static parseValueUi(columnId: fixmeAny, text: fixmeAny) {
      try {
        return this.parseValue(columnId, text);
      } catch (e) {
        alert("Invalid value: " + e.message);
        throw e;
      }
    }

    public static PLACEHOLDER = {};

    public static addCell(addColumnId: fixmeAny, ancestorQCellId: fixmeAny, enteredValue: fixmeAny, callback: fixmeAny = (() => {}), consumePlaceholder: fixmeAny = false) {
      let newValue: fixmeAny;
      if (enteredValue == StateEdit.PLACEHOLDER) {
        newValue = null;
      } else {
        newValue = this.parseValueUi(addColumnId, enteredValue);
        if (newValue == null)
          return;
      }
      $$.call("addCellRecursive", addColumnId, ancestorQCellId, newValue, consumePlaceholder,
        (error: fixmeAny, result: fixmeAny) => {
          if (error == null) {
            // Try to move the selection to the added cell, once it shows up.
            let predicate: fixmeAny;
            if (enteredValue == StateEdit.PLACEHOLDER) {
              predicate = (c: fixmeAny) =>
                c.addColumnId == addColumnId &&
                EJSON.equals(c.ancestorQCellId, {columnId: getColumn(addColumnId).parent, cellId: result}) &&
                c.isPlaceholder;
            } else {
              predicate = (c: fixmeAny) =>
                EJSON.equals(c.qCellId, {columnId: addColumnId, cellId: cellIdChild(result, newValue)});
            }
            postSelectionPredicate(predicate);
          }
          callback(error, result);
        });
    }

    public static modifyCell(qCellId: fixmeAny, enteredValue: fixmeAny, callback: fixmeAny = () => {}) {
      let newValue: fixmeAny;
      let cel = new CellId(qCellId);
      if ((newValue = this.parseValueUi(cel.columnId, enteredValue)) != null) {
        cel.value(newValue, (() => {
          $$.call("notify", callback);
        }));
      }
    }

    public static removeCell(qCellId: fixmeAny, callback: fixmeAny = () => {}) {
      new CellId(qCellId).remove((() => {
        $$.call("notify", callback);
      }));
    }

    public static canEdit(columnId: fixmeAny) {
      let col = getColumn(columnId);
      // May as well not let the user try to edit _unit.
      return (col != null) && columnIsState(col) && (col.type !== "_token" && col.type !== "_unit");
    }
  }

  function insertBlankColumn(parentId: fixmeAny, index: fixmeAny, isObject: fixmeAny, view: fixmeAny) {
    // Obey the restriction on a state column as child of a formula column.
    // Although changeColumnFormula allows this to be bypassed anyway... :(
    let formula = getColumn(parentId).formula != null ? DUMMY_FORMULA : null;
    if (isObject && (formula == null)) {
      $$.call("insertUnkeyedStateObjectTypeWithField", parentId, index, nextAvailableColumnName("Object"), nextAvailableColumnName("value"), DEFAULT_STATE_FIELD_TYPE, view != null ? view.id : null, standardServerCallback);  // specifiedType
    } else {
      $$.call("defineColumn", parentId, index, nextAvailableColumnName("value"), formula != null ? null : DEFAULT_STATE_FIELD_TYPE, isObject, null, formula, view != null ? view.id : null, standardServerCallback);  // specifiedType  // isObject  // objectName: when it is applicable, [fieldName] is OK  // formula
    }
  }

  export class ClientView {
    public options: fixmeAny;
    public hot: fixmeAny;
    public savedSelection: fixmeAny;
    public layoutTree: fixmeAny;
    public mainSection: fixmeAny;
    public qCellIdToGridCoords: fixmeAny;
    public grid: fixmeAny;
    public colClasses: fixmeAny;
    public cellClasses: fixmeAny;
    private pending: Array<String>;

    constructor(public view: fixmeAny) {
      this.options = {
        // Show type row in header
        // Currently shown, otherwise users too often forget to set the type.
        // Consider turning this off when we guess the type based on entered data.
        // ~ Matt 2015-12-03
        showTypes: true,
        // Pretty self-explanatory...
        headerInitiallyExpanded: true,
        canToggleHeaderExpansion: true,
        // 'boring' for grey, 'alternating' for two greys, 'rainbow' for dazzling colors
        palette: "alternating",
        // Matching colors for fields of reference type and their target object columns.
        colorReferences: true,
        // If true, show bullets for every object type.  If false, hide bullets except
        // for object types with no children (for UI prototyping; not all functionality
        // works in this mode).
        showBullets: true,
        rootSpareRows: 10,
        // Developers only (print some logs with timestamps)
        profile: false,

        // We've stopped maintaining these options because they weren't worth
        // the complexity they added to the already very complex rendering code.
        // They are now fixed at the values shown below.

        // Separator column between every pair of adjacent incomparable columns
        // (except ones that are in separate tables when separateTables is on).
        //
        // Will be more workable once we have column plurality data.  I still
        // feel that separator columns have merit and we should consider turning
        // them back on the future if we don't come up with something better.
        // ~ Matt 2016-09-15
        sepcols: false,
        // Show children of the root as separate tables.
        separateTables: true,
      };

      this.headerExpanded = new ReactiveVar(this.options.headerInitiallyExpanded);
      this.hot = null;
      this.savedSelection = null;
      this.pending = [];

      this.reload();
    }

    public reload() {
      this.layoutTree = this.view.def().layout;
      this.mainSection = new ViewSection(this.layoutTree, this.options);
    }

    public hotConfig() {
      let _ref: fixmeAny, _results: fixmeAny;
      let thisView = this;
      if (this.options.profile) console.log(`[${stamp()}]  ---  preparing grid started  --- `);
      // Display the root column for completeness.  However, it doesn't have a real
      // value.
      let hlist = this.mainSection.prerenderHlist([], "");
      // XXX This is in addition to any placeholders.  Desirable?
      hlist.minHeight += this.options.rootSpareRows;
      let typeColors = new EJSONKeyedMap();
      if (this.options.colorReferences) {
        this.mainSection.findTypesToColor(typeColors);
        this.mainSection.assignTypeColors(0, typeColors);
      }
      let grid = this.mainSection.renderHeader(this.headerExpanded.get(), this.headerExpanded.get() ? this.mainSection.headerMinHeight : 3, 0, typeColors);
      for (let row of grid) {
        for (let cell of row) {
          cell.cssClasses.push("htBottom", "rsHeader");  // easiest to do here
        }
      }
      let headerHeight = grid.length;
      if (!this.options.showTypes) {  // HACK: Delete the last header row
        grid.pop();
        grid.forEach((row: fixmeAny, i: fixmeAny) => {
          for (let cell of row) {
            if (cell.rowspan > grid.length - i) {
              cell.rowspan = grid.length - i;
            }
          }
        });
      }
      let gridData = this.mainSection.renderHlist(hlist, null, hlist.minHeight);
      gridVertExtend(grid, gridData);

      //gridCaption = []
      if (this.options.canToggleHeaderExpansion) {
        if (headerHeight > 2 && this.mainSection.showBullets) {
          let toggleHtml = `<svg class="toggleHeaderExpanded" style="height: 11px; width: 10px">\n  <path style="stroke: black; fill: black" d="${this.headerExpanded.get() ? "M 1 4 l 8 0 l -4 4 z" : "M 3 1 l 4 4 l -4 4 z"}"/>\n</svg>`;
          grid[0][0].value = toggleHtml;
          grid[0][0].cssClasses.push("rsRoot");
        }
      }

      if (!this.options.showTypes) {  // HACK: Same
        //gridCaption.pop()
        headerHeight = headerHeight - 1;
      }

      // Add last column that will stretch horizontally
      let sentinel = grid.map((row: fixmeAny) => [new ViewCell("", 1, 1, ["rsSentinel"])]);
      sentinel[0][0].columnId = rootColumnId;
      sentinel[0][0].rowspan = sentinel.length;
      gridHorizExtend(grid, sentinel);

      // Resolve cell cross-references.
      // @ notation disabled; relevant code commented out. ~ Matt 2015-11-10
      this.qCellIdToGridCoords = new EJSONKeyedMap();
      grid.forEach((rowCells: fixmeAny, i: fixmeAny) => {
        rowCells.forEach((cell: fixmeAny, j: fixmeAny) => {
          if ((cell.qCellId != null) && cell.isObjectCell) {
            this.qCellIdToGridCoords.set(cell.qCellId, {
              row: i,
              col: j
            });
          }
        });
      });
      for (let row of grid) {
        for (let cell of row) {
          if (cell.value instanceof CellReference) {
            cell.referent = cell.value.qCellId;
            cell.display = cell.value.display;
          }
        }
      }

      this.grid = grid;

      if (this.options.profile) console.log(`[${stamp()}]  ---  preparing grid finished  --- `);

      this.colClasses = _.range(0, grid[0].length).map((col) => {
        let colCls: fixmeAny = null;
        for (let row = 0; row < grid.length; row++) {
          for (let cls of grid[row][col].cssClasses) {
            if (cls === "rsCaption" || cls === "rsRoot" || cls === "tableSeparator") {
              // assert (!colCls? || colCls == cls)
              colCls = cls;
            }
          }
        }
        return colCls;
      });

      this.cellClasses = grid.map((dataRow: fixmeAny, row: fixmeAny) => dataRow.map((cell: fixmeAny, col: fixmeAny) => {
        let refc: fixmeAny;
        let adjcol = col + cell.colspan;
        let classes: string[] = [];
        if ((cell.qCellId != null) && cell.isObjectCell && ((refc = this.refId(cell.qCellId)) != null)) {
          classes.push(`ref-${refc}`);
        }
        let ancestors = cell.qCellId != null ? new CellId(cell.qCellId).ancestors() : cell.ancestorQCellId != null ? new CellId(cell.ancestorQCellId).ancestors() : [];
        for (let ancestor of ancestors) {
          if ((refc = this.refId(ancestor.q())) != null) {
            classes.push(`ancestor-${refc}`);
          }
        }
        if ((cell.kind === "top" || cell.kind === "below") && cell.columnId !== rootColumnId
            || (cell.qCellId != null) && !cell.isObjectCell && StateEdit.canEdit(cell.qCellId.columnId)
            // We don't have state columns as descendants of formula columns, so
            // if we can edit addColumnId, we'll also be able to insert the
            // ancestors.
            || (cell.addColumnId != null) && !cell.isObjectCell && StateEdit.canEdit(cell.addColumnId))
          classes.push("editable");
        return cell.cssClasses.concat(classes);
      }));

      return {
        data: grid.map((row: fixmeAny) => row.map((cell: fixmeAny) => fallback(cell.display, cell.value))),
        // Future: Fixing the ancestors of the leftmost visible column would be
        // clever, though with carefully designed individual views, we may never
        // need it.  We may also want to fix the header for large data sets.
        //fixedColumnsLeft: 1  # Caption removed
        colWidths: _.range(0, this.grid[0].length).map((i) => {  // no way grid can be empty
          switch (this.colClasses[i]) {
            case "tableSeparator":
              return 20;
            case "rsRoot":
              return 18;
            default:
              // NOTE!  Auto column size only works if this is undefined, not null.
              return undefined;
          }
        }),
        rowHeights: (() => {
          // Specify all the row heights (24 pixels is the Handsontable default),
          // otherwise the fixed clone of the left column sometimes reduced the
          // objectName row to zero height because it wasn't constrained by the
          // content of the real table.  We can look out for any similar glitches.
          if (this.headerExpanded.get()) {
            return _.range(0, this.grid.length).map((i) => i < headerHeight - (2 + this.options.showTypes) ? 11 : 24);
          } else {
            return _.range(0, this.grid.length).map((i) => 24);
          }
        })(),
        stretchH: "last",
        cells: (row: fixmeAny, col: fixmeAny, prop: fixmeAny): fixmeAny => {
          let clsRow = this.cellClasses[row];
          let classes = clsRow != null ? clsRow[col] : null;
          if (!classes) {
            return {};  // may occur if grid is changing
          }

          if (this.pending.indexOf(`${row}-${col}`) >= 0) {
            classes = classes.concat("pending");  // must copy classes because at this point it aliases an element of this.cellClasses
          }
          return {
            renderer: col === 0 && row === 0 ? "html" : "text",
            className: classes.join(" "),
            // Edge case: renaming the column whose formula is currently being edited could change
            // the string representation of the original formula, which would trigger a reactive
            // update that would lose the unsaved changes.
            // XXX Remove when we have better handling of changes to the original formula in general.
            //
            // Make this nonreactive: Handsontable will requery it when the user
            // starts editing, and we don't want to rebuild the table when it
            // changes.  Don't use readOnly because that would dim the cells, which
            // we think is more than is appropriate.
            editor: Tracker.nonreactive(() => ActionBar.hasUnsavedData()) ? false : "text",
            // Only column header "top" and "below" cells can be edited,
            // for the purpose of changing the objectName and fieldName respectively.
            //
            // qFamilyId is the add case.  For a state keyed object, you add by typing the key in the padding cell.
            readOnly: classes.indexOf("editable") == -1
          };
        },
        autoColumnSize: {
          // I saw glitches with the asynchronous sizing on the cost sheet.  Rather
          // than investigate, I'm happy to go back to synchronous for now.
          // ~ Matt 2015-11-21
          syncLimit: "100%"
        },
        mergeCells: (_ref = []).concat.apply(_ref, grid.map((row: fixmeAny, i: fixmeAny) => {
          _results = [];
          for (let j = 0; j < row.length; j++) {
            let cell = row[j];
            if (cell.rowspan !== 1 || cell.colspan !== 1) {
              _results.push({
                row: i,
                col: j,
                rowspan: cell.rowspan,
                colspan: cell.colspan
              });
            }
          }
          return _results;
        })),
        // We don't have a principled design for how the selection should move
        // after pressing Enter, and for now, the default behavior is causing
        // surprises when it moves the selection to the padding cell at the bottom
        // of a family, which is mapped by the "select similar cell" code to the
        // first cell in the family.
        enterMoves: {
          row: 0,
          col: 0
        },
        // Seems more helpful to the user (e.g., when scrolling the browser window).
        // See if we have trouble with the user needing to "escape" from the table.
        outsideClickDeselects: false,
        afterDeselect: () => {
          thisView.onSelection();
        },
        afterSelection: (r1: fixmeAny, c1: fixmeAny, r2: fixmeAny, c2: fixmeAny) => {
          thisView.onSelection();
        },
        beforeKeyDown: (event: fixmeAny) => {
          thisView.onKeyDown(event);
        },
        afterRender: (isForced: fixmeAny) => {
          if (isForced) this.pending = []; // this is the best way to make sure no "dirt" is left
        },
        beforeChange: (changes: fixmeAny, source: fixmeAny) => {
          if (!source) return true;   // Run this handler only for interactive edits

          let fail = false;
          for (let [row, col, oldVal, newVal] of changes) {
            if (oldVal === newVal) continue;

            let cell = this.grid[row][col];
            let revertingCallback = (error: fixmeAny, result: fixmeAny) => {
              if (error) {
                fail = true;  // prevent race condition in case we're still in this function
                this.pending = [];
                this.hot.setDataAtCell(row, col, oldVal);
              }
              standardServerCallback(error, result);
            };
            this.pending.push(`${row}-${col}`);

            // One of these cases should apply...
            let name: string;
            if (cell.kind === "top") {
              name = newVal === "" ? null : newVal;
              Meteor.call("changeColumnObjectName", $$, cell.columnId, name, revertingCallback);
            }
            if (cell.kind === "below") {
              name = newVal === "" ? null : newVal;
              Meteor.call("changeColumnFieldName", $$, cell.columnId, name, revertingCallback);
            }
            // Currently, types can only be changed via the action bar.
            //if cell.kind == 'type'
            //  parsed = false
            //  try
            //    type = if newVal == '' then null else parseTypeStr(newVal)
            //    parsed = true
            //  catch e
            //    alert('Invalid type.')
            //  if parsed
            //    Meteor.call 'changeColumnSpecifiedType', $$, cell.columnId, type,
            //                standardServerCallback
            try {
              if ((cell.qCellId != null) && !cell.isObjectCell) {
                // XXX Once we validate values, we should replace the hard-coded
                // check for 'text' with an attempt to validate the input.
                // Currently not allowing empty strings as this is the only way to catch
                // cell deletion keystroke (see comment in onKeyDown).
                if (newVal) {  // || getColumn(cell.qCellId.columnId).type == 'text'
                  StateEdit.modifyCell(cell.qCellId, newVal, revertingCallback);
                } else {
                  if (this.getDeleteCommandForCell(cell) != null) {
                    this.getDeleteCommandForCell(cell).callback();
                  }
                  //StateEdit.removeCell cell.qCellId, standardServerCallback
                }
              } else if ((cell.addColumnId != null) && !cell.isObjectCell) {
                if (newVal || getColumn(cell.addColumnId).type === "text") {
                  StateEdit.addCell(cell.addColumnId, cell.ancestorQCellId, newVal, revertingCallback, cell.isPlaceholder);
                }
              }
            } catch (e) {
              fail = true;   // Note: this reverts all changes.
                             // The ones that have been applied will propagate back through
                             // Meteor collections.
            }
          }

          if (fail) return false;


          // Don't apply the changes directly; let them come though the Meteor
          // stubs.  This ensures that they get reverted by Meteor if the server
          // call fails.
          //return false;
          return true;
        },
        contextMenu: {
          build: (): fixmeAny => {
            let addCommand: fixmeAny, ci: fixmeAny, coords: fixmeAny, deleteCommand: fixmeAny, demoteCommand: fixmeAny;
            if (ActionBar.hasUnsavedData()) {
              return false;
            }

            let c = fallback(this.getSingleSelectedCell(), {});

            let items = <fixmeAny>{};

            if ((ci = c.columnId) != null) {
              let col = getColumn(ci);
              let objectName = fallback(objectNameWithFallback(col), "(unnamed)");
              let fieldName = fallback(col.fieldName, "(unnamed)");
              if (!col.isObject) {
                items.promote = {
                  name: columnIsState(col) ? `Wrap '${fieldName}' values in objects` : `Generate objects for '${fieldName}' values`,
                  callback: () => {
                    Meteor.call("changeColumnIsObject", $$, ci, true, standardServerCallback);
                  }
                };
              }
              // If !col.isObject, then the defineColumn (or the first defineColumn
              // of the insertUnkeyedStateObjectTypeWithField) will automatically
              // promote col.
              let addFieldItem = {
                name: ci === rootColumnId ? "Add global value column to sheet" : col.isObject ? `Add value column to '${objectName}'` : "...and add another value column",
                callback: () => {
                  let index = col.children.length;
                  insertBlankColumn(ci, index, false, this.view);
                }
              };
              let addObjectTypeItem = {
                name: ci === rootColumnId ? "Add object column to sheet" : col.isObject ? `Add nested object column to '${objectName}'` : "...and add a nested object column",
                callback: () => {
                  let index = col.children.length;
                  insertBlankColumn(ci, index, true, this.view);
                }
              };
              if (ci === rootColumnId) {  // order tweak for common case
                items.addObjectTypeItem = addObjectTypeItem;
                items.addField = addFieldItem;
              } else {
                items.addField = addFieldItem;
                items.addObjectTypeItem = addObjectTypeItem;
              }
              if ((demoteCommand = this.getDemoteCommandForColumn(col))) {
                items.demote = demoteCommand;
              }

              // Don't allow a keyed object column and its key column to be deleted
              // with a single command, since I couldn't find a label for the
              // command that wasn't confusing.  Hopefully it's clear that "Remove
              // generated objects" is the first step toward deleting a keyed
              // object column.
              if (ci !== rootColumnId && col.children.length === 0 && (!col.isObject || col.type === "_token")) {
                items["delete"] = {
                  name: col.isObject ? `Delete '${objectName}' object column` : `Delete '${fieldName}' value column`,
                  callback: () => {
                    this.hot.deselectCell();  // <- Otherwise changeColumn form gets hosed.
                    Meteor.call("deleteColumn", $$, ci, standardServerCallback);
                  }
                };
              }
            } else {
              if ((c.referent != null) && ((coords = this.qCellIdToGridCoords.get(c.referent)) != null)) {
                items.jumpToReferent = {
                  name: `Jump to object '${c.display}'`,
                  callback: () => {
                    this.selectSingleCell(coords.row, coords.col);
                  }
                };
              }
              if ((addCommand = this.getAddCommandForCell(c)) != null) {
                items.add = addCommand;
              }
              if ((deleteCommand = this.getDeleteCommandForCell(c)) != null) {
                items["delete"] = deleteCommand;
              }
            }

            function isEmpty(o: fixmeAny) {
              for (let k in o) {
                return false;
              }
              return true;
            }
            if (isEmpty(items)) {
              items.nothing = {
                name: "No actions available here",
                disabled: () => true
              };
            }

            return {
              items: items  // end of build callback  // contextMenu  // Handsontable config object
            };
          }
        }
      };
    }

    public hotCreate(domElement: fixmeAny) {
      let cfg = this.hotConfig();
      this.hot = new Handsontable(domElement, cfg);
      $(domElement).addClass(`pal-${this.options.palette}`);
      if (this.options.showTypes) {
        $(domElement).addClass("showTypes");
      }
      // Monkey patch: Don't let the user merge or unmerge cells.
      this.hot.mergeCells.mergeOrUnmergeSelection = (cellRange: fixmeAny) => {};
    }

    public hotReconfig() {
      // @savedSelection is not meaningful after we update the table.
      this.savedSelection = null;
      let cfg = this.hotConfig();
      this.hot.updateSettings({
        colWidths: cfg.colWidths,
        rowHeights: cfg.rowHeights,
        mergeCells: cfg.mergeCells
      });
      /*
       * Tried this as an optimization. Didn't seem to be faster (sometimes slower)
       * than just running loadData. Might be different on larger spreadsheets though,
       * so I'm leaving it here for reference.   ~ Shachar, 2-24-2016
       *
      cfg.data.forEach((dataRow, row) =>
        dataRow.forEach((dataElem, col) => {
          if (dataElem !== this.hot.getDataAtCell(row, col)) {
            this.hot.setDataAtCell(row, col, dataElem);
          }
        })
      )
      */
      this.hot.loadData(cfg.data);
    }

    public getSelected = () => {
      let s: fixmeAny;
      if ((s = this.hot.getSelected()) != null) {
        let [r1, c1, r2, c2] = s;
        [r1, r2] = [Math.min(r1, r2), Math.max(r1, r2)];
        [c1, c2] = [Math.min(c1, c2), Math.max(c1, c2)];
        return [r1, c1, r2, c2];
      } else {
        return null;
      }
    }

    public getSingleSelectedCell = () => {
      let s = this.getSelected();
      if (s == null) {
        // This can happen if no selection was made since page was loaded
        return null;
      }
      let [r1, c1, r2, c2] = s;
      let cell = this.grid[r1][c1];
      if (r2 === r1 + cell.rowspan - 1 && c2 === c1 + cell.colspan - 1) {
        return cell;
      } else {
        return null;
      }
    }

    public getMultipleSelectedCells = () => {
      let cells: fixmeAny = [];
      for (let coord of this.hot.getSelectedRange().getAll()) {
        let cell = this.grid[coord.row][coord.col];
        if (cell.value != null) {
          cells.push(cell);
        }
      }
      return cells;
    }

    public refId(qCellId: fixmeAny) {
      //if qCellId.columnId == rootColumnId
      //  "root"
      //else
      let loc = this.qCellIdToGridCoords.get(qCellId);
      return loc != null ? `${loc.row}-${loc.col}` : null;
    }

    public highlightReferent(referent: fixmeAny) {
      let refc: fixmeAny;
      $(".referent").removeClass("referent");
      $(".referent-object").removeClass("referent-object");
      if ((referent != null) && ((refc = this.refId(referent)) != null)) {
        $(`.ref-${refc}`).addClass("referent");
        $(`.ancestor-${refc}`).addClass("referent-object");
      }
    }

    public highlightObject(obj: fixmeAny) {
      let refc: fixmeAny;
      $(".selected-object").removeClass("selected-object");
      if ((obj != null) && ((refc = this.refId(obj)) != null)) {
        $(`.ancestor-${refc}`).addClass("selected-object");
      }
    }

    public onSelection() {
      let ci: fixmeAny, _ref: fixmeAny;
      let selection = this.hot.getSelected();
      if (EJSON.equals(selection, this.savedSelection)) {
        return;
      }
      if (ActionBar.hasUnsavedData()) {
        if (this.savedSelection != null) {
          (_ref = this.hot).selectCell.apply(_ref, this.savedSelection);
        } else {
          // I don't think this should happen, but don't crash. ~ Matt
          this.hot.deselectCell();
        }
        return;
      }
      this.savedSelection = selection;
      selectedCell = this.getSingleSelectedCell();
      ActionBar.fullTextToShow.set(selectedCell != null ? selectedCell.fullText : null);
      this.highlightReferent(selectedCell != null ? selectedCell.referent : null);
      this.highlightObject((selectedCell != null ? selectedCell.isObjectCell : null) ? selectedCell.qCellId : null);
      // _id: Hacks to get the #each to clear the forms when the cell changes.
      ActionBar.changeColumnArgs.set((selectedCell != null) && ((ci = selectedCell.columnId) != null) && ci !== rootColumnId ? [
        {
          _id: ci,
          columnId: ci,
          onObjectHeader: selectedCell.isObjectHeader
        }
      ] : []);
    }

    // get*CommandForCell return a context menu item, but onKeyDown also uses
    // just the callback, so we maintain consistency in what command is offered.

    public getAddCommandForCell(c: fixmeAny) {
      let col: fixmeAny;
      if ((c.addColumnId != null) && columnIsState(col = getColumn(c.addColumnId))) {
        let objectName = fallback(objectNameWithFallback(col), "(unnamed)");
        if (col.type === "_token") {
          // A token column has only the object UI-column, though we don't set
          // isObjectCell on family padding cells.  So don't check it.
          return {
            name: `Add '${objectName}' object here`,
            allowEnter: true,
            callback: () => {
              StateEdit.addCell(c.addColumnId, c.ancestorQCellId, null, standardServerCallback);
            }
          };
        } else if (col.type === "_unit") {
          // Adding a duplicate value has no effect, but disallow it as a
          // hint to the user.  !c.isObjectCell is in principle a
          // requirement, though it ends up being redundant because the only way
          // to select an object cell is to already have a unit value present.
          let fam: fixmeAny;
          if (!c.isObjectCell && !(
                col.parent == c.ancestorQCellId.columnId &&
                (fam = Cells.findOne({column: col._id, key: c.ancestorQCellId.cellId})) != null &&
                fam.values != null && fam.values.length > 0)) {
            return {
              name: "Add X here",
              allowEnter: true,
              callback: () => {
                StateEdit.addCell(c.addColumnId, c.ancestorQCellId, null, standardServerCallback);
              }
            };
          }
        } else {
          if (!c.isObjectCell) {
            return {
              // I'd like to make clear that this doesn't actually add the value yet
              // (e.g., "Make room to add a value here"), but Daniel won't like that.
              // ~ Matt 2015-11-22
              name: "Add cell here",
              // We want enter to start editing instead.
              // XXX Share code with the calculation of the "editable" class.
              allowEnter: false,
              callback: () => {
                StateEdit.addCell(c.addColumnId, c.ancestorQCellId, StateEdit.PLACEHOLDER, standardServerCallback);
              }
            };
          }
        }
      }
      return null;
    }

    public getDeleteCommandForCell(c: fixmeAny) {
      let col: fixmeAny;
      if (c.isPlaceholder) {  // Should only exist in state value columns.
        return {
          name: "Delete cell",
          callback: () => {
            new FamilyId({columnId: c.addColumnId,
                          cellId: c.ancestorQCellId.cellId})
              .removePlaceholder(standardServerCallback);
          }
        };
      } else if ((c.qCellId != null) && columnIsState(col = getColumn(c.qCellId.columnId))) {
        return {
          // This currently gives 'Delete object' for the key of a keyed object
          // (deprecated).  If we wanted that case to say 'Delete cell', we
          // would test c.isObjectCell instead.
          name: col.isObject ? "Delete object" : "Delete cell",
          callback: () => {
            StateEdit.removeCell(c.qCellId, standardServerCallback);
          }
        };
      } else {
        return null;
      }
    }

    public getDemoteCommandForColumn(col: fixmeAny) {
      if (col._id !== rootColumnId && col.isObject && col.children.length === (col.type === "_token" ? 1 : 0)) {
        let objectName = fallback(objectNameWithFallback(col), "(unnamed)");
        //parentName = objectNameWithFallback(getColumn(col.parent)) ? '(unnamed)'
        //flattenFieldName =
        //  (if col.type == '_token'
        //    getColumn(col.children[0]).fieldName
        //  else
        //    col.fieldName) ? '(unnamed)'
        return {
          name: col.type === "_token" ? `Flatten out '${objectName}' objects` : `Remove generated '${objectName}' objects`,
          callback: () => {
            Meteor.call("changeColumnIsObject", $$, col._id, false, standardServerCallback);
          }
        };
      }
      return null;
    }

    public onKeyDown(event: fixmeAny) {
      let ci: fixmeAny, col: fixmeAny, parentCol: fixmeAny, qf: fixmeAny;
      if (ActionBar.hasUnsavedData()) {
        return;
      }
      selectedCell = this.getSingleSelectedCell();
      if (event.altKey && event.metaKey) {
        Handsontable.Dom.stopImmediatePropagation(event);
      } else if (!event.altKey && !event.ctrlKey && !event.metaKey) {
        if (event.which === 13) {  // Enter
          let cmd = this.getAddCommandForCell(selectedCell);
          if (cmd != null && cmd.allowEnter) {
            Handsontable.Dom.stopImmediatePropagation(event);
            cmd.callback();
          }
        } else if (event.which === 46 || event.which === 8) {  // Delete / Backspace
          // Be careful not to hijack focus when an editor is open
          if (this.hot.getActiveEditor().state !== "STATE_EDITING") {
            Handsontable.Dom.stopImmediatePropagation(event);
            for (let cell of this.getMultipleSelectedCells()) {
              if (this.getDeleteCommandForCell(cell) != null) {
                this.getDeleteCommandForCell(cell).callback();
              }
            }
          }
        }
      } else if (event.ctrlKey && !event.altKey && !event.metaKey) {
        if (event.which === 13) {  // Ctrl+Enter
          Handsontable.Dom.stopImmediatePropagation(event);
          if (selectedCell != null) {
            if (this.getAddCommandForCell(selectedCell) != null) {
              this.getAddCommandForCell(selectedCell).callback();
            }
          }
        }
      } else if (event.altKey && !event.ctrlKey && !event.metaKey) {
        // Use Alt + Left/Right to reorder columns inside parent
        //     Alt + Up/Down to make column into object/value
        if (event.which === 37 || event.which === 39 || event.which === 38 || event.which === 40) {
          Handsontable.Dom.stopImmediatePropagation(event);
          event.stopPropagation();
          event.preventDefault();

          if ((selectedCell != null) && ((ci = selectedCell.columnId) != null) && ((col = getColumn(ci)) != null) && (col.parent != null) && (parentCol = getColumn(col.parent))) {
            if (this.view.id != null) {
              let t = this.view.def().layout;
              console.log(t.find(ci));
              console.log(t.find(col.parent));
              console.log(t.find(col.parent).subtrees.length);
              console.log(t.find(col.parent).subtrees.indexOf(t.find(ci)));
              let parentNode = t.find(col.parent);
              let n = parentNode.subtrees.length;
              let index = parentNode.subtrees.indexOf(t.find(ci));
              if (event.which === 37 && index > 0) {  // Left
                this.view.reorderColumn(ci, index - 1);
              } else if (event.which === 39 && index < n - 1) {  // Right
                this.view.reorderColumn(ci, index + 1);
              }
            } else {
              let n = parentCol.children.length;
              let index = parentCol.children.indexOf(ci);
              if (event.which === 37 && index > 0) {  // Left
                $$.call("reorderColumn", ci, index - 1, standardServerCallback);
              } else if (event.which === 39 && index < n - 1) {  // Right
                $$.call("reorderColumn", ci, index + 1, standardServerCallback);
              } else if (event.which === 38 && !col.isObject) {  // Up
                $$.call("changeColumnIsObject", ci, true, standardServerCallback);
              } else if (event.which === 40) {  // Down
                // Check whether this should be possible (i.e., right children)
                // before attempting it so we can detect real errors from the server.
                if (this.getDemoteCommandForColumn(col) != null) {
                  this.getDemoteCommandForColumn(col).callback();
                }
              }
            }
          }
        }
      }
    }

    public selectSingleCell(r1: fixmeAny, c1: fixmeAny) {
      let cell = this.grid[r1][c1];
      this.hot.selectCell(r1, c1, r1 + cell.rowspan - 1, c1 + cell.colspan - 1);
    }

    public selectMatchingCell(predicate: fixmeAny) {
      for (let i = 0; i < this.grid.length; i++) {
        for (let j = 0; j < this.grid[i].length; j++) {
          if (predicate(this.grid[i][j])) {
            this.selectSingleCell(i, j);
            return true;
          }
        }
      }
      return false;
    }

    public headerExpanded: fixmeAny;
    public toggleHeaderExpanded() {
      this.headerExpanded.set(!this.headerExpanded.get());
    }

  }

  export let sheetView: fixmeAny = null;

  export function rebuildView(viewId: fixmeAny) {
    if (!sheetView || !sheetView.hot) {
      if ((sheetView != null ? sheetView.hot : null) != null) {
        sheetView.hot.destroy();
      }
      sheetView = new ClientView(new View(viewId));
      sheetView.hotCreate($("#View")[0]);  //View')[0]
    } else {
      sheetView.reload();  //viewDef
      sheetView.hotReconfig();
    }

    Tracker.nonreactive(() => {
      // Nothing below should trigger rebuilding of the view if it reads reactive
      // data sources.  (Ouch!)

      if (pendingSelectionPredicate != null &&
          sheetView.selectMatchingCell(pendingSelectionPredicate)) {
        pendingSelectionPredicate = null;
      } else if (selectedCell != null) {
        // Try to select a cell similar to the one previously selected.
        let cases: [boolean, SelectionPredicate][] = [
          [selectedCell.qCellId != null,
          (newCell) => EJSON.equals(selectedCell.qCellId, newCell.qCellId) &&
            selectedCell.isObjectCell === newCell.isObjectCell],
          [selectedCell.addColumnId != null,
          (newCell) => selectedCell.addColumnId == newCell.addColumnId &&
            EJSON.equals(selectedCell.ancestorQCellId, newCell.ancestorQCellId)],
          [selectedCell.addColumnId != null,
          (newCell) => (newCell.kind === "below" || newCell.kind === "tokenObject-below") &&
            EJSON.equals(selectedCell.addColumnId, newCell.columnId)],
          [selectedCell.kind != null,
          (newCell) => selectedCell.kind === newCell.kind &&
            selectedCell.columnId === newCell.columnId],
        ];
        for (let [guard, predicate] of cases) {
          if (guard && sheetView.selectMatchingCell(predicate))
            break;
        }
      }
      // Make sure various things are consistent with change in table data or
      // selection (view.selectMatchingCell doesn't always seem to trigger this).
      sheetView.onSelection();
      ActionBar.isLoading.set(false);
    });
  }

  // Hm, using the pre-makeErrorType class as the TypeScript type is a little
  // awkward but the best way I can think of. ~ Matt 2016-09-19
  export let whyNotReady: NotReadyError_ = null;

  // Helper decorator for use with Tracker.autorun
  export function guarded(op: fixmeAny) {
    return (...args: fixmeAny[]) => {
      try {
        op.apply(null, args);
      } catch (e) {
        if (e instanceof NotReadyError) {
          whyNotReady = e;
          return;  // Let the autorun run again once we have the data.
        }
        throw e;
      }
      whyNotReady = null;
    };
  }

  function stamp() {
    let d = new Date();
    return d.toString("HH:mm:ss.") + ("000" + d.getMilliseconds()).slice(-3);
  }

  Template["Spreadsheet"].rendered = function(this: fixmeAny) {
    let sheet = (this.data != null ? this.data.sheet : null) || "";
    let viewId = this.data != null ? this.data.viewId : null;
    // $('body').addClass("present")   # uncomment for presentation mode (read from query string?)
    if (sheet) {
      document.title = sheet;
    }
    RelsheetsClient.open(sheet);
    Tracker.autorun(guarded(() => {
      rebuildView(viewId);
    }));
  };

  Template["Spreadsheet"].events = {
    "click .toggleHeaderExpanded": () => {
      sheetView.toggleHeaderExpanded();
    }
  };

  Template["Spreadsheet"].helpers({
    // TODO: Find a less hacky way to make this happen? ~ Matt 2015-10-01
    actionBarClass: () => ActionBar.isExpanded() ? "actionBarExpanded" : "",
    selectionLockClass: () => ActionBar.hasUnsavedData() ? "selectionLock" : ""
  });

}
