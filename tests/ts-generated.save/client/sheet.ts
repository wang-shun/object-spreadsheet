namespace Objsheets {

  Router.route("/:sheet", function() {
    this.render("Spreadsheet", {
      data: {
        sheet: this.params.sheet
      }
    });
  });
  Router.route("/:sheet/views/:_id", function() {
    this.render("Spreadsheet", {
      data: {
        sheet: this.params.sheet,
        viewId: this.params._id
      }
    });
  });

  class NotReadyError_ {
    constructor(public message) {}
  }
  let NotReadyError = Meteor.makeErrorType("NotReadyError", NotReadyError_);

  // Object that can be used as ViewCell.value or ViewHlist.value to defer the
  // resolution of the target cell ID to a row number.  I'm a terrible person for
  // taking advantage of heterogeneous fields in JavaScript... ~ Matt
  export class CellReference {
    constructor(public qCellId, public display) {}
  }

  export function stringifyTypeForSheet(type) {
    var col, name;
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

  export function markDisplayClassesForType(type) {
    return type === "_unit" ? ["centered"] : [];
  }

  class ViewVlist {
    constructor(public parentCellId, public minHeight, public hlists, public numPlaceholders?, public error?) {}
  }

  class ViewHlist {
    constructor(public cellId, public minHeight, public value, public error, public vlists) {}
  }

  class ViewSection {
    public columnId;
    public col;
    public relationSingular;
    public width;
    public leftEdgeSingular;
    public rightEdgeSingular;
    public extraColClassBefore;
    public subsections;
    public headerHeightBelow;
    public amRootWithSeparateTables;
    public headerMinHeight;

    constructor(public layoutTree, public options : fixmeAny = {}) {
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
      this.width = (this.col.type !== "_token") + !!this.col.isObject;
      this.leftEdgeSingular = true;
      this.rightEdgeSingular = true;
      // field index -> string or null (class of extra column before this field)
      this.extraColClassBefore = [];
      this.subsections = [];
      // @headerHeightBelow and @headerMinHeight refer to the expanded header.
      this.headerHeightBelow = 2;  // fieldName, type
      this.amRootWithSeparateTables = this.options.separateTables && this.columnId === rootColumnId;
      this.layoutTree.subtrees.forEach((sublayout, i) => {
        let subsection = new ViewSection(sublayout, this.options);
        this.subsections.push(subsection);
        let nextLeftEdgeSingular = subsection.relationSingular && subsection.leftEdgeSingular;
        let extraColClass = this.options.separateTables && this.col._id === rootColumnId && i > 0 ? "tableSeparator" : this.options.sepcols && !this.rightEdgeSingular && !nextLeftEdgeSingular ? "separator" : null;
        this.extraColClassBefore.push(extraColClass);
        if (extraColClass != null) {
          this.width++;
        }
        this.width += subsection.width;
        this.headerHeightBelow = Math.max(this.headerHeightBelow, subsection.headerMinHeight);
        this.rightEdgeSingular = subsection.relationSingular && subsection.rightEdgeSingular;
      });
      this.headerMinHeight = (this.col.isObject && !this.amRootWithSeparateTables) + this.headerHeightBelow;
      if (this.col.isObject) {
        // Affects empty sheet when @options.separateTables = true.
        this.headerMinHeight = Math.max(this.headerMinHeight, 3);
      }
    }

    public prerenderVlist(parentCellId) {
      let ce = Cells.findOne({
        column: this.columnId,
        key: parentCellId
      });
      if ((ce != null ? ce.values : null) != null) {
        let hlists = ce.values.map((value) => this.prerenderHlist(cellIdChild(parentCellId, value), value));
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

    public prerenderHlist(cellId, value) {
      let minHeight = 1;
      try {
        let displayValue = valueToText(liteModel, this.col.type, value);
        if (typeIsReference(this.col.type)) {
          displayValue = new CellReference({
            columnId: this.col.type,
            cellId: value
          }, displayValue);
        }
        let error = null;
      } catch (e) {
        displayValue = null;
        error = e.message;
      }
      let vlists = this.subsections.map((subsection) => subsection.prerenderVlist(cellId));
      minHeight = Math.max.apply(Math, [1].concat(vlists.map((vlist) => vlist.minHeight)));
      return new ViewHlist(cellId, minHeight, displayValue, error, vlists);
    }

    public renderVlist(vlist, height) {
      let qFamilyId = {
        columnId: this.columnId,
        cellId: vlist.parentCellId
      };
      if (vlist.hlists != null) {
        let grid = [];
        for (let hlist of vlist.hlists) {
          gridVertExtend(grid, this.renderHlist(hlist, hlist.minHeight));
        }
        for (let cell of gridBottomRow(grid)) {
          cell.cssClasses.push("vlast");
        }
        for (let i = 0; i < vlist.numPlaceholders; i++) {
          let placeholder = gridMergedCell(1, this.width, "", ["dataPadding"]);
          placeholder[0][0].qFamilyId = qFamilyId;
          placeholder[0][0].isPlaceholder = true;
          gridVertExtend(grid, placeholder);
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
            // Add blank cell at bottom
            let bottomGrid = gridMergedCell(height - grid.length, this.width, "", ["dataPadding"]);
            bottomGrid[0][0].qFamilyId = qFamilyId;
            gridVertExtend(grid, bottomGrid);
          }
        }
      } else {
        grid = gridMergedCell(height, this.width, "error", ["dataError"]);
        grid[0][0].fullText = "Error: " + vlist.error;
        grid[0][0].qFamilyId = qFamilyId;
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

    public findTypesToColor(typeColors) {
      if (typeIsReference(this.col.type)) {
        typeColors.set(this.col.type, "TBD");
      }
      for (let subsection of this.subsections) {
        subsection.findTypesToColor(typeColors);
      }
    }

    public assignTypeColors(nextColor, typeColors) {
      if (typeColors.get(this.columnId) === "TBD") {
        typeColors.set(this.columnId, nextColor++);
      }
      for (let subsection of this.subsections) {
        nextColor = subsection.assignTypeColors(nextColor, typeColors);
      }
      return nextColor;
    }

    public renderHlist(hlist, height) {
      let grid = _.range(0, height).map((i) => []);
      let qCellId = {
        columnId: this.columnId,
        cellId: hlist.cellId
      };
      // This logic could be in a ViewCell accessor instead, but for now it isn't
      // duplicated so there's no need.
      let qFamilyId = this.columnId === rootColumnId ? null : {
        columnId: this.columnId,
        cellId: cellIdParent(hlist.cellId)
      };
      if (this.col.isObject) {
        // Object
        let gridObject = gridMergedCell(height, 1, this.objectSymbol(), ["centered"]);
        gridObject[0][0].qCellId = qCellId;
        gridObject[0][0].qFamilyId = qFamilyId;
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
        let gridValue = gridMergedCell(height, 1, fallback(hlist.value, "<?>"));
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
        gridValue[0][0].qCellId = qCellId;
        gridValue[0][0].qFamilyId = qFamilyId;
        gridHorizExtend(grid, gridValue);
      }
      // Subsections
      this.subsections.forEach((subsection, i) => {
        if (this.extraColClassBefore[i] != null) {
          let extraCells = gridMergedCell(height, 1, "", [this.extraColClassBefore[i]]);
          if (this.extraColClassBefore[i] === "separator") {
            // Include separator cells in object region highlighting (but for now,
            // not table separator cells for the root object).  Do not set qCellId
            // as that would allow "Delete object", which would be a little
            // surprising.
            extraCells[0][0].ancestorQCellId = qCellId;
          }
          gridHorizExtend(grid, extraCells);
        }
        let subsectionGrid = subsection.renderVlist(hlist.vlists[i], height);
        gridHorizExtend(grid, subsectionGrid);
      });
      return grid;
    }

    // As long as siblings are always separated by a separator, we can color just
    // based on depth.
    // If !expanded, then the requested height should always be 3.  Leaves render
    // at height 2 anyway.

    public renderHeader(expanded, height, depth, typeColors) {
      // Part that is always the same.
      var fieldMatchIdx, matchIdx;
      let myDepthClass = "rsHeaderDepth" + this.colorIndexForDepth(this.col.isObject ? depth : depth - 1);
      // Currently matching-colored header cells don't depend on depth.  You could
      // argue we should generate two classes and let the CSS deal with it.
      let myColorClass = (matchIdx = typeColors.get(this.columnId)) != null ? "rsHeaderMatch" + this.colorIndexForMatch(matchIdx) : myDepthClass;
      let grid = [[], []];  // c.f. renderHlist
      if (this.col.isObject) {
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
        fieldNameCell = new ViewCell(fallback(this.col.fieldName, ""), 1, 1, [(this.col.isObject ? "rsHeaderFieldNameKey" : "rsHeaderFieldNameLeaf"), myFieldColorClass]);
        fieldNameCell.columnId = this.columnId;
        fieldNameCell.kind = "below";
        let typeName = stringifyTypeForSheet(this.col.type);
        // The type is essential to interpret values in the column.  The rest of
        // the attributes are no more important than the formula itself, which we
        // currently show only in the action bar, so don't show them here.
        typeCell = new ViewCell(typeName, 1, 1, [(this.col.isObject ? "rsHeaderTypeKey" : "rsHeaderTypeLeaf"), myFieldColorClass].concat(this.markDisplayClasses()));
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
      let makeCorner = (isFinal) => {
        let classes = ["rsHeaderCorner"];
        if (!isFinal) {
          classes.push("rsHeaderNonfinal");
        }
        classes.push(myColorClass);
        let corner = gridMergedCell(height - 2, grid[0].length, fallback(this.col.objectName, ""), classes);
        corner[0][0].columnId = this.columnId;
        corner[0][0].isObjectHeader = true;
        corner[0][0].kind = "top";
        gridVertExtend(corner, grid);
        grid = corner;
        currentHeight = height;
      };

      this.subsections.forEach((subsection, i) => {
        if (this.extraColClassBefore[i] != null) {
          if (this.extraColClassBefore[i] === "tableSeparator" && currentHeight === 2) {
            // Close off the corner for the root object so we can draw a complete
            // table separator column.
            makeCorner(true);
          }
          let cssClasses = [this.extraColClassBefore[i]];
          if (this.extraColClassBefore[i] !== "tableSeparator") {
            cssClasses.push(myColorClass);
          }
          let gridExtraCol = gridMergedCell(currentHeight, 1, "", cssClasses);
          gridHorizExtend(grid, gridExtraCol);
        }
        let subHeight = expanded ? this.headerHeightBelow : 3;
        let subsectionGrid = subsection.renderHeader(expanded, subHeight, depth + 1, typeColors);
        if (currentHeight === 2 && subsectionGrid.length > 2) {
          makeCorner(false);  // may increase currentHeight so next condition holds
        }
        if (subsectionGrid.length < currentHeight) {
          cssClasses = [myColorClass];
          if (i < this.subsections.length - 1 && !this.amRootWithSeparateTables) {
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

    public colorIndexForDepth(depth) {
      switch (this.options.palette) {
        case "rainbow":
          return depth % 6;
        case "alternating":
          return depth % 2;
        default:
          return 0;
      }
    }

    public colorIndexForMatch(matchIdx) {
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
  let selectedCell = null;

  export class StateEdit {
    public static parseValue(qFamilyId, text) {
      let type = getColumn(qFamilyId.columnId).type;
      //if typeIsReference(type)
      //  if (m = /^@(\d+)$/.exec(text))
      //    wantRowNum = Number.parseInt(m[1])
      //    for [qCellId, coords] in view.qCellIdToGridCoords.entries()
      //      if qCellId.columnId == type && coords.dataRow == wantRowNum
      //        return qCellId.cellId
      //    throw new Error("Column #{type} contains no cell at row #{wantRowNum}.")
      return parseValue(type, text);
    }

    public static parseValueUi(qFamilyId, text) {
      try {
        return this.parseValue(qFamilyId, text);
      } catch (e) {
        alert("Invalid value: " + e.message);
        return null;
      }
    }

    public static addCell(qFamilyId, enteredValue, callback : fixmeAny = (() => {}), consumePlaceholder : fixmeAny = false) {
      var newValue;
      if ((newValue = this.parseValueUi(qFamilyId, enteredValue)) != null) {
        new FamilyId(qFamilyId).add(newValue, (() => {
          $$.call("notify", callback);
        }), consumePlaceholder);
      }
    }

    public static modifyCell(qCellId, enteredValue, callback : fixmeAny = () => {}) {
      var newValue;
      let cel = new CellId(qCellId);
      let fam = cel.family();
      if ((newValue = this.parseValueUi(fam, enteredValue)) != null) {
        cel.value(newValue, (() => {
          $$.call("notify", callback);
        }));
      }
    }

    public static removeCell(qCellId, callback : fixmeAny = () => {}) {
      new CellId(qCellId).remove((() => {
        $$.call("notify", callback);
      }));
    }

    public static canEdit(columnId) {
      let col = getColumn(columnId);
      // May as well not let the user try to edit _unit.
      return (col != null) && columnIsState(col) && (col.type !== "_token" && col.type !== "_unit");
    }
  }

  function insertBlankColumn(parentId, index, isObject, view) {
    // Obey the restriction on a state column as child of a formula column.
    // Although changeColumnFormula allows this to be bypassed anyway... :(
    let formula = getColumn(parentId).formula != null ? DUMMY_FORMULA : null;
    if (isObject && (formula == null)) {
      $$.call("insertUnkeyedStateObjectTypeWithField", parentId, index, nextAvailableColumnName("Object"), nextAvailableColumnName("value"), DEFAULT_STATE_FIELD_TYPE, view != null ? view.id : null, standardServerCallback);  // specifiedType
    } else {
      $$.call("defineColumn", parentId, index, nextAvailableColumnName("value"), formula != null ? null : DEFAULT_STATE_FIELD_TYPE, isObject, null, formula, view != null ? view.id : null, standardServerCallback);  // specifiedType  // isObject  // objectName: when it is applicable, [fieldName] is OK  // formula
    }
  }

  let headerExpanded = new ReactiveVar(true);
  function toggleHeaderExpanded() {
    headerExpanded.set(!headerExpanded.get());
  }

  export class ClientView {
    public options;
    public hot;
    public savedSelection;
    public layoutTree;
    public mainSection;
    public qCellIdToGridCoords;
    public grid;
    public colClasses;

    constructor(public view) {
      this.options = {
        // Show type row in header
        // Currently shown, otherwise users too often forget to set the type.
        // Consider turning this off when we guess the type based on entered data.
        // ~ Matt 2015-12-03
        showTypes: true,
        // Show arrow button to open hierarchical header
        headerExpandable: true,
        // 'boring' for grey, 'alternating' for two greys, 'rainbow' for dazzling colors
        palette: "alternating",
        // Matching colors for fields of reference type and their target object columns.
        colorReferences: true,
        // Separator column between every pair of adjacent incomparable columns
        // (except ones that are in separate tables when separateTables is on).
        // Consider turning back on once we have column plurality data. ~ Matt 2015-12-04
        sepcols: false,
        // Show children of the root as separate tables.
        separateTables: true
      };
      this.hot = null;
      this.savedSelection = null;

      this.reload();
    }

    public reload() {
      this.layoutTree = this.view.def().layout;
      this.mainSection = new ViewSection(this.layoutTree, this.options);
    }

    public hotConfig() {
      var _ref, _results;
      let thisView = this;
      // Display the root column for completeness.  However, it doesn't have a real
      // value.
      let hlist = this.mainSection.prerenderHlist([], "");
      let typeColors = new EJSONKeyedMap();
      if (this.options.colorReferences) {
        this.mainSection.findTypesToColor(typeColors);
        this.mainSection.assignTypeColors(0, typeColors);
      }
      let grid = this.mainSection.renderHeader(headerExpanded.get(), headerExpanded.get() ? this.mainSection.headerMinHeight : 3, 0, typeColors);
      for (let row of grid) {
        for (let cell of row) {
          cell.cssClasses.push("htBottom", "rsHeader");  // easiest to do here
        }
      }
      let headerHeight = grid.length;
      if (!this.options.showTypes) {  // HACK: Delete the last header row
        grid.pop();
        grid.forEach((row, i) => {
          for (let cell of row) {
            if (cell.rowspan > grid.length - i) {
              cell.rowspan = grid.length - i;
            }
          }
        });
      }
      let gridData = this.mainSection.renderHlist(hlist, hlist.minHeight);
      gridVertExtend(grid, gridData);

      //gridCaption = []
      if (this.options.headerExpandable) {
        if (headerHeight > 2) {
          let toggleHtml = `<svg class="toggleHeaderExpanded" style="height: 11px; width: 10px">\n  <path style="stroke: black; fill: black" d="${headerExpanded.get() ? "M 1 4 l 8 0 l -4 4 z" : "M 3 1 l 4 4 l -4 4 z"}"/>\n</svg>`;
          grid[0][0].value = toggleHtml;
          grid[0][0].cssClasses.push("rsRoot");
          //gridVertExtend(gridCaption,
          //               gridMergedCell(headerHeight - 2, 1, toggleHtml + ' Obj', ['htBottom', 'rsCaption']))
        }
        //gridCaption.push(
        //  [new ViewCell('Field', 1, 1, ['rsCaption'])],
        //  [new ViewCell('Type', 1, 1, ['rsCaption'])])
      }
      //else
      //  gridVertExtend(gridCaption,
      //                 gridMergedCell(headerHeight - 1, 1, "", ['htBottom', 'rsCaption']))
      //  gridVertExtend(gridCaption,
      //                 gridMergedCell(1, 1, "", ['rsCaption']))

      if (!this.options.showTypes) {  // HACK: Same
        //gridCaption.pop()
        headerHeight = headerHeight - 1;
      }
      //gridVertExtend(gridCaption,
      //               ([new ViewCell("@#{i+1}", 1, 1, ['rsCaption','rsRowNum'])] for i in [0...gridData.length]))
      //gridHorizExtend(gridCaption, grid)
      //grid = gridCaption

      // Add last column that will stretch horizontally
      let sentinel = grid.map((row) => [new ViewCell("", 1, 1, ["rsSentinel"])]);
      sentinel[0][0].columnId = rootColumnId;
      sentinel[0][0].rowspan = sentinel.length;
      gridHorizExtend(grid, sentinel);

      // Resolve cell cross-references.
      // @ notation disabled; relevant code commented out. ~ Matt 2015-11-10
      this.qCellIdToGridCoords = new EJSONKeyedMap();
      grid.forEach((rowCells, i) => {
        rowCells.forEach((cell, j) => {
          if ((cell.qCellId != null) && cell.isObjectCell) {
            this.qCellIdToGridCoords.set(cell.qCellId, {
              row: i,
              col: j
            });
            //# dataRow is user-facing row number, one-based.
            // dataRow: i - headerHeight + 1
          }
        });
      });
      for (let row of grid) {
        for (let cell of row) {
          if (cell.value instanceof CellReference) {
            cell.referent = cell.value.qCellId;
            cell.display = cell.value.display;  // ? '@' + (@qCellIdToGridCoords.get(cell.value.qCellId)?.dataRow || '?')
          }
        }
      }

      this.grid = grid;

      this.colClasses = _.range(0, grid[0].length).map((col) => {
        let colCls = null;
        for (let row = 0; row < grid.length; row++) {
          for (let cls of grid[row][col].cssClasses) {
            if (cls === "rsCaption" || cls === "rsRoot" || cls === "separator" || cls === "tableSeparator") {
              // assert (!colCls? || colCls == cls)
              colCls = cls;
            }
          }
        }
        return colCls;
      });

      return {
        data: grid.map((row) => row.map((cell) => fallback(cell.display, cell.value))),
        // Future: Fixing the ancestors of the leftmost visible column would be
        // clever, though with carefully designed individual views, we may never
        // need it.  We may also want to fix the header for large data sets.
        //fixedColumnsLeft: 1  # Caption removed
        // Separator columns are 8 pixels wide.  Others use default width.
        colWidths: _.range(0, this.grid[0].length).map((i) => {  // no way grid can be empty
          switch (this.colClasses[i]) {
            case "tableSeparator":
              return 20;
            case "separator":
              return 10;
            case "rsRoot":
              return 18;
            default:
              return undefined;
          }
        }),
        rowHeights: ((function() {
          // Specify all the row heights (24 pixels is the Handsontable default),
          // otherwise the fixed clone of the left column sometimes reduced the
          // objectName row to zero height because it wasn't constrained by the
          // content of the real table.  We can look out for any similar glitches.
          if (headerExpanded.get()) {
            return _.range(0, this.grid.length).map((i) => i < headerHeight - (2 + this.options.showTypes) ? 11 : 24);
          } else {
            return _.range(0, this.grid.length).map((i) => 24);
          }
        }).call(this)),
        stretchH: "last",
        cells: (row, col, prop) => {
          var refc;
          cell = this.grid[row] != null ? this.grid[row][col] : null;
          if (!cell) {
            return {};  // may occur if grid is changing
          }
          let adjcol = col + cell.colspan;
          let classes = this.colClasses[adjcol] === "separator" ? ["incomparable"] : [];
          if ((cell.qCellId != null) && cell.isObjectCell && ((refc = this.refId(cell.qCellId)) != null)) {
            classes.push(`ref-${refc}`);
          }
          if ((cell.qFamilyId != null ? cell.qFamilyId.cellId.length : null) === 0) {  // seems to work; == undefined if qFamilyId doesn't exist
            classes.push("parent-root");
          }
          let ancestors = cell.ancestorQCellId != null ? new CellId(cell.ancestorQCellId).ancestors() : cell.qCellId != null ? new CellId(cell.qCellId).ancestors() : cell.qFamilyId != null ? new FamilyId(cell.qFamilyId).ancestors() : [];
          for (let ancestor of ancestors) {
            if ((refc = this.refId(ancestor.q())) != null) {
              classes.push(`ancestor-${refc}`);
            }
          }
          return {
            renderer: col === 0 && row === 0 ? "html" : "text",
            className: (cell.cssClasses.concat(classes)).join(" "),
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
            readOnly: !((cell.kind === "top" || cell.kind === "below") && cell.columnId !== rootColumnId || (cell.qCellId != null) && !cell.isObjectCell && StateEdit.canEdit(cell.qCellId.columnId) || (cell.qFamilyId != null) && !cell.isObjectCell && StateEdit.canEdit(cell.qFamilyId.columnId))
          };
        },
        autoColumnSize: {
          // I saw glitches with the asynchronous sizing on the cost sheet.  Rather
          // than investigate, I'm happy to go back to synchronous for now.
          // ~ Matt 2015-11-21
          syncLimit: "100%"
        },
        mergeCells: (_ref = []).concat.apply(_ref, grid.map((row, i) => {
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
        afterSelection: (r1, c1, r2, c2) => {
          thisView.onSelection();
        },
        beforeKeyDown: (event) => {
          thisView.onKeyDown(event);
        },
        beforeChange: (changes, source) => {
          for (let [row, col, oldVal, newVal] of changes) {
            cell = this.grid[row][col];
            // One of these cases should apply...
            if (cell.kind === "top") {
              let name = newVal === "" ? null : newVal;
              Meteor.call("changeColumnObjectName", $$, cell.columnId, name, standardServerCallback);
            }
            if (cell.kind === "below") {
              name = newVal === "" ? null : newVal;
              Meteor.call("changeColumnFieldName", $$, cell.columnId, name, standardServerCallback);
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
            if ((cell.qCellId != null) && !cell.isObjectCell) {
              // XXX Once we validate values, we should replace the hard-coded
              // check for 'text' with an attempt to validate the input.
              // Currently not allowing empty strings as this is the only way to catch
              // cell deletion keystroke (see comment in onKeyDown).
              if (newVal) {  // || getColumn(cell.qCellId.columnId).type == 'text'
                StateEdit.modifyCell(cell.qCellId, newVal, standardServerCallback);
              } else {
                if (this.getDeleteCommandForCell(cell) != null) {
                  this.getDeleteCommandForCell(cell).callback();
                }
                //StateEdit.removeCell cell.qCellId, standardServerCallback
              }
            } else if ((cell.qFamilyId != null) && !cell.isObjectCell) {
              if (newVal || getColumn(cell.qFamilyId.columnId).type === "text") {
                StateEdit.addCell(cell.qFamilyId, newVal, standardServerCallback, cell.isPlaceholder);
              }
            }
          }
          // Don't apply the changes directly; let them come though the Meteor
          // stubs.  This ensures that they get reverted by Meteor if the server
          // call fails.
          return false;
        },
        contextMenu: {
          build: () => {
            var addCommand, ci, coords, deleteCommand, demoteCommand;
            if (ActionBar.hasUnsavedData()) {
              return false;
            }

            let c = fallback(this.getSingleSelectedCell(), {});

            let items = {};

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

            function isEmpty(o) {
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

    public hotCreate(domElement) {
      let cfg = this.hotConfig();
      this.hot = new Handsontable(domElement, cfg);
      $(domElement).addClass(`pal-${this.options.palette}`);
      if (this.options.showTypes) {
        $(domElement).addClass("showTypes");
      }
      // Monkey patch: Don't let the user merge or unmerge cells.
      this.hot.mergeCells.mergeOrUnmergeSelection = (cellRange) => {};
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
      this.hot.loadData(cfg.data);
    }

    public getSelected = () => {
      var s;
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
      let cells = [];
      for (let coord of this.hot.getSelectedRange().getAll()) {
        let cell = this.grid[coord.row][coord.col];
        if (cell.value != null) {
          cells.push(cell);
        }
      }
      return cells;
    }

    public refId(qCellId) {
      //if qCellId.columnId == rootColumnId
      //  "root"
      //else
      let loc = this.qCellIdToGridCoords.get(qCellId);
      return loc != null ? `${loc.row}-${loc.col}` : null;
    }

    public highlightReferent(referent) {
      var refc;
      $(".referent").removeClass("referent");
      if ((referent != null) && ((refc = this.refId(referent)) != null)) {
        $(`.ref-${refc}`).addClass("referent");
      }
    }

    public highlightObject(obj) {
      var refc;
      $(".selected-object").removeClass("selected-object");
      if ((obj != null) && ((refc = this.refId(obj)) != null)) {
        $(`.ancestor-${refc}`).addClass("selected-object");
      }
    }

    public onSelection() {
      var ci, _ref;
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

    public getAddCommandForCell(c) {
      var col;
      let qf = c.qFamilyId;
      if ((qf != null) && columnIsState(col = getColumn(qf.columnId))) {
        let objectName = fallback(objectNameWithFallback(col), "(unnamed)");
        if (col.type === "_token") {
          // A token column has only the object UI-column, though we don't set
          // isObjectCell on family padding cells.  So don't check it.
          return {
            name: `Add '${objectName}' object here`,
            callback: () => {
              StateEdit.addCell(qf, null, standardServerCallback);
            }
          };
        } else if (col.type === "_unit") {
          // Adding a duplicate value has no effect, but disallow it as a
          // hint to the user.  !selectedCell.isObjectCell is in principle a
          // requirement, though it ends up being redundant because the only way
          // to select an object cell is to already have a unit value present.
          if (!selectedCell.isObjectCell && !(Cells.findOne({
            column: qf.columnId,
            key: qf.cellId
          }) != null ? Cells.findOne({
            column: qf.columnId,
            key: qf.cellId
          }).values != null ? Cells.findOne({
            column: qf.columnId,
            key: qf.cellId
          }).values.length : null : null)) {
            return {
              name: "Add X here",
              callback: () => {
                StateEdit.addCell(qf, null, standardServerCallback);
              }
            };
          }
        } else {
          if (!selectedCell.isObjectCell) {
            return {
              // I'd like to make clear that this doesn't actually add the value yet
              // (e.g., "Make room to add a value here"), but Daniel won't like that.
              // ~ Matt 2015-11-22
              name: "Add cell here",
              callback: () => {
                new FamilyId(qf).addPlaceholder(standardServerCallback);
              }
            };
          }
        }
      }
      return null;
    }

    public getDeleteCommandForCell(c) {
      var col;
      if (c.isPlaceholder) {  // Should only exist in state value columns.
        return {
          name: "Delete cell",
          callback: () => {
            new FamilyId(c.qFamilyId).removePlaceholder(standardServerCallback);
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

    public getDemoteCommandForColumn(col) {
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

    public onKeyDown(event) {
      var ci, col, parentCol, qf;
      if (ActionBar.hasUnsavedData()) {
        return;
      }
      selectedCell = this.getSingleSelectedCell();
      if (event.altKey && event.metaKey) {
        Handsontable.Dom.stopImmediatePropagation(event);
      } else if (!event.altKey && !event.ctrlKey && !event.metaKey) {
        if (event.which === 13) {  // Enter
          // Like the "add by editing" case of hotConfig.readOnly but handles the rest of the types.
          if (((qf = selectedCell != null ? selectedCell.qFamilyId : null) != null) && columnIsState(col = getColumn(qf.columnId)) && (col.type === "_token" || col.type === "_unit")) {
            Handsontable.Dom.stopImmediatePropagation(event);
            this.getAddCommandForCell(selectedCell).callback();
          }
        } else if (event.which === 46 || event.which === 8) {  // Delete / Backspace
          // Be careful not to hijack focus when an editor is open
          if (this.hot.getActiveEditor().state !== "STATE_EDITING") {
            Handsontable.Dom.stopImmediatePropagation(event);
            for (let cell of this.getMultipleSelectedCells()) {
              if (((qf = cell != null ? cell.qFamilyId : null) != null) && columnIsState(col = getColumn(qf.columnId))) {
                if (this.getDeleteCommandForCell(cell) != null) {
                  this.getDeleteCommandForCell(cell).callback();
                }
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
              n = parentCol.children.length;
              index = parentCol.children.indexOf(ci);
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

    public selectSingleCell(r1, c1) {
      let cell = this.grid[r1][c1];
      this.hot.selectCell(r1, c1, r1 + cell.rowspan - 1, c1 + cell.colspan - 1);
    }

    public selectMatchingCell(predicate) {
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
  }

  let view = null;

  export function rebuildView(viewId) {
    if (!view || !view.hot) {
      if ((view != null ? view.hot : null) != null) {
        view.hot.destroy();
      }
      view = new ClientView(new View(viewId));
      view.hotCreate($("#View")[0]);  //View')[0]
    } else {
      view.reload();  //viewDef
      view.hotReconfig();
    }
    this.view = view;  // for debugging

    Tracker.nonreactive(() => {
      // Nothing below should trigger rebuilding of the view if it reads reactive
      // data sources.  (Ouch!)

      // Try to select a cell similar to the one previously selected.
      if (selectedCell != null) {
        ((selectedCell.qCellId != null) && view.selectMatchingCell((c) => EJSON.equals(selectedCell.qCellId, c.qCellId) && selectedCell.isObjectCell === c.isObjectCell)) || ((selectedCell.qFamilyId != null) && view.selectMatchingCell((c) => EJSON.equals(selectedCell.qFamilyId, c.qFamilyId))) || ((selectedCell.qFamilyId != null) && view.selectMatchingCell((c) => (c.kind === "below" || c.kind === "tokenObject-below") && EJSON.equals(selectedCell.qFamilyId.columnId, c.columnId))) || ((selectedCell.kind != null) && view.selectMatchingCell((c) => selectedCell.kind === c.kind && selectedCell.columnId === c.columnId)) || false;
      }
      // Make sure various things are consistent with change in table data or
      // selection (view.selectMatchingCell doesn't always seem to trigger this).
      view.onSelection();
      ActionBar.isLoading.set(false);
    });
  }

  // Helper decorator for use with Tracker.autorun
  export function guarded(op) {
    return (...args) => {
      try {
        op.apply(null, args);
      } catch (e) {
        if (e instanceof NotReadyError) {
          window.why = e;
          return;  // Let the autorun run again once we have the data.
        }
        throw e;
      }
      window.why = null;
    };
  }

  Template["Spreadsheet"].rendered = function() {
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
      toggleHeaderExpanded();
    }
  };

  Template["Spreadsheet"].helpers({
    // TODO: Find a less hacky way to make this happen? ~ Matt 2015-10-01
    actionBarClass: () => ActionBar.isExpanded() ? "actionBarExpanded" : "",
    selectionLockClass: () => ActionBar.hasUnsavedData() ? "selectionLock" : ""
  });

}
