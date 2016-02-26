namespace Objsheets {

  let fullTextToShow = new ReactiveVar(null);
  let isLoading = new ReactiveVar(true);

  Template["actionBar"].helpers({
    loading: () => isLoading.get(),
    fullTextToShow: () => fullTextToShow.get(),
    changeColumnArgs: () => changeColumnArgs.get()
  });

  //
  // Template changeColumn
  //
  let changeColumnArgs = new ReactiveVar([], EJSON.equals);

  let NESTED_UNDERLINING_PX_PER_LEVEL = 4;
  let NESTED_UNDERLINING_MAX_DEPTH = 5;

  // We mainly care that this doesn't crash.
  function origFormulaStrForData(data) {
    if (data.onObjectHeader) {
      return null;
    }
    let col = getColumn(data.columnId);
    let formula = col != null ? col.formula : null;
    return formula == null ? null : EJSON.equals(formula, DUMMY_FORMULA) ? "" : stringifyFormula(col.parent, formula);
  }

  let origFormulaStr = new ReactiveVar(null);
  Tracker.autorun(() => {
    let cca = changeColumnArgs.get()[0];
    origFormulaStr.set(cca != null ? origFormulaStrForData(cca) : null);
  });
  let newFormulaStr = new ReactiveVar(null);
  let newFormulaInfo = new ReactiveVar(null);

  let isFormulaDebuggerOpen = new ReactiveVar(false);

  let tracingView = null;

  Template["changeColumn"].rendered = function() {
    // XXX What if there are unsaved changes when the formula changes externally?
    this.autorun(() => {
      newFormulaStr.set(origFormulaStr.get());
    });
    this.autorun(() => {
      if (!isFormulaDebuggerOpen.get()) {
        let info = newFormulaInfo.get();
        if ((info != null ? info.selectedBand : null) != null) {
          info.selectedBand.selected = false;
          info.selectedBand = null;
          // Retriggers this autorun, but it will do nothing the second time.
          newFormulaInfo.set(info);
        }
        if (tracingView != null) {
          tracingView.destroy();
        }
        return tracingView = null;
      }
    });
    this.autorun(() => {
      let shouldShowFormulaBar = newFormulaStr.get() != null;
      if (shouldShowFormulaBar && (this.codeMirror == null)) {
        // Have to wait for the template to re-render with the new div.
        // afterFlush will become unmaintainable if we push it much further, but
        // works for now and is easier than trying to figure out the referencing
        // for a child template.
        Tracker.afterFlush(() => {
          changeColumnInitFormulaBar(this);
        });
      } else if (!shouldShowFormulaBar && (this.codeMirror != null)) {
        // TODO: Consider allowing the action bar to remain expanded when the user
        // switches columns.  But if we make the toggle button always visible, it
        // will be less clear that it is related to the formula.
        isFormulaDebuggerOpen.set(false);
        for (let c of this.formulaBarComputations) {
          c.stop();
        }
        this.formulaBarComputations = null;
        newFormulaInfo.set(null);
        // XXX Do we need to tear down the CodeMirror somehow?
        this.codeMirror = null;
      }
    });
  };

  Template["changeColumn"].destroyed = () => {
    // Try to avoid holding on to data that's no longer relevant.
    // XXX: Should we rather define the reactive vars on the template instance?
    // Then we'd need more Template.instance() from the helpers.
    isFormulaDebuggerOpen.set(false);
    if (tracingView != null) {
      tracingView.destroy();
    }
    tracingView = null;
    newFormulaInfo.set(null);
    newFormulaStr.set(null);
  };

  // Scanning for all possible reference types is slow enough to make the selection
  // feel laggy, so cache the menu and reuse it.
  let typeMenuCommonItems = new ReactiveVar([]);
  Relsheets.onOpen(() => {
    Tracker.autorun(() => {
      // Note: It's possible to create cycles in the "key + parent" relation on
      // object types.  This is a pointless thing to do but does not break our
      // tool; it's as if all of those reference types were merely empty.  So
      // don't try to prevent it for now.
      let refItems = [];
      function scan(colId) {
        let c = getColumn(colId);
        if (c == null) {
          return;  // Not ready?  What a pain.
        }
        if (colId !== rootColumnId && c.isObject) {
          refItems.push(new HtmlOption(colId, stringifyType(colId)));
        }
        for (let childId of c.children) {
          scan(childId);
        }
      }
      scan(rootColumnId);

      let items = [];
      items.push(new HtmlOptgroup("Basic types", MAIN_PRIMITIVE_TYPES.map((t) => new HtmlOption(t, t))));
      items.push(new HtmlOptgroup("Reference to:", refItems));
      typeMenuCommonItems.set(items);
    });
  });

  Template["changeColumn"].helpers({
    //col: -> getColumn(@columnId)
    isFormulaModified: () => newFormulaStr.get() !== origFormulaStr.get(),
    canSave: () => {
      // Looks like this can be called before the autorun that sets newFormulaInfo.  Grr.
      return newFormulaStr.get() !== origFormulaStr.get() && ((newFormulaInfo.get() != null ? newFormulaInfo.get().formula : null) != null);
    },
    columnName: function() {
      return stringifyColumnRef([this.columnId, !this.onObjectHeader]);
    },
    keyColumnName: function() {
      let c = getColumn(this.columnId);
      return this.onObjectHeader && c.type !== "_token" ? c.fieldName : null;
    },
    typeMenu: function() {
      let col = getColumn(this.columnId);
      let items = [];
      if (col.formula != null) {
        // Note: Inferred type should match c.type if c.specifiedType is null and
        // there are no unsaved changes to the formula.
        let info = newFormulaInfo.get();
        let inferredTypeDesc = (info != null ? info.formula != null ? info.formula.type : null : null) != null ? stringifyType(info.formula.type) : "error";
        items.push(new HtmlOption("auto", `auto (${inferredTypeDesc})`));
      }
      for (let item of typeMenuCommonItems.get()) {
        items.push(item);
      }
      return new HtmlSelect(items, fallback(col.specifiedType, "auto"));
    },
    backendMenu: function() {
      return new HtmlSelect([new HtmlOption("state", "editable"), new HtmlOption("computed", "computed by formula")], getColumn(this.columnId).formula != null ? "computed" : "state");
    },
    isComputed: function() {
      return getColumn(this.columnId).formula != null;
    },
    newFormulaInfo: () => newFormulaInfo.get(),
    isFormulaDebuggerOpen: () => isFormulaDebuggerOpen.get(),
    contextText: function() {
      let col = getColumn(this.columnId);
      return col.isObject ? fallback(objectNameWithFallback(getColumn(col.parent)), "(unnamed)") : null;  // i.e., we are editing the formula of a key column
    },
    // Color-coding is much less useful with non-rainbow palettes.
    //contextColorIndex: ->
    //  col = getColumn(@columnId)
    //  if col.isObject
    //    colorIndexForDepth(columnDepth(col.parent))
    //  else null
    // Should only be called when onObjectHeader = true
    referenceDisplayColumnMenu: function() {
      let col = getColumn(this.columnId);
      let defaultColId = defaultReferenceDisplayColumn(col);
      let defaultColDesc = defaultColId != null ? fallback(getColumn(defaultColId).fieldName, "unnamed") : "none";
      let items = [new HtmlOption("auto", `Choose automatically (${defaultColDesc})`)];
      for (let displayColId of allowedReferenceDisplayColumns(col)) {
        let displayCol = getColumn(displayColId);
        items.push(new HtmlOption(displayColId, fallback(displayCol.fieldName, "(unnamed)")));
      }
      return new HtmlSelect(items, fallback(col.referenceDisplayColumn, "auto"));
    }
  });

  function changeColumnInitFormulaBar(template) {
    let formula = origFormulaStr.get();
    template.codeMirror = CodeMirror(template.find("#changeFormula-formula"), {  //changeFormula-formula'), {
      value: "",  // filled in by autorun below
      extraKeys: {
        Enter: (cm) => {
          template.find(".saveFormula").click();
        },
        Esc: (cm) => {
          template.find(".revertFormula").click();
        }
      }
    });
    template.codeMirrorDoc = template.codeMirror.getDoc();
    template.formulaBarComputations = [
      template.autorun(() => {
        // http://stackoverflow.com/a/15256593
        let height = template.codeMirror.defaultTextHeight() + 2 * 4;
        if (isFormulaDebuggerOpen.get()) {
          height += NESTED_UNDERLINING_PX_PER_LEVEL * NESTED_UNDERLINING_MAX_DEPTH;
        }
        template.codeMirror.setSize("100%", height);
      }), template.autorun(() => {
        let formulaStr = newFormulaStr.get();
        if (formulaStr == null) {
          // When the formula is cleared, sometimes this runs before the autorun
          // that tears down the formula bar.  Grr, Meteor, how are we supposed to
          // avoid these problems in general?
          return;
        }
        // Avoid re-setting in response to user input, since this sends the cursor
        // back to the beginning.  Wish for a better two-way binding mechanism...
        if (formulaStr !== template.codeMirrorDoc.getValue()) {
          template.codeMirrorDoc.setValue(formulaStr);
        }
        newFormulaInfo.set(generateFormulaInfo(template));
      })
    ];
    template.codeMirror.on("beforeChange", (cm, change) => {
      if (change.update != null) {
        let newtext = change.text.join("").replace(/\n/g, "");
        change.update(null, null, [newtext]);
      }
      // Otherwise, change is coming from undo or redo; hope it's OK.
    });
    template.codeMirror.on("changes", (cm) => {
      newFormulaStr.set(template.codeMirrorDoc.getValue());
    });
  }

  function generateFormulaInfo(template) {
    if (tracingView != null) {
      tracingView.destroy();
    }
    tracingView = null;
    let formulaStr = newFormulaStr.get();
    let formulaInfo = {};
    if (formulaStr === "") {
      formulaInfo.formula = DUMMY_FORMULA;
      // Do not construct a subformula tree.
      return formulaInfo;
    }
    let parentColumnId = getColumn(template.data.columnId).parent;
    try {
      formulaInfo.formula = parseFormula(parentColumnId, formulaStr);
      // Fill in vars expando field on all subformulas.  Obviously in the future
      // we want to be able to help troubleshoot ill-typed formulas, but we punt
      // all error tolerance until later rather than fight that complexity now.
      typecheckFormula(liteModel, new EJSONKeyedMap([["this", parentColumnId]]), formulaInfo.formula);
    } catch (e) {
      if (!(e instanceof FormulaValidationError)) {
        throw e;
      }
      // TODO: More graceful error handling
      formulaInfo.error = e.message;
      return formulaInfo;
    }
    formulaInfo.root = getSubformulaTree(formulaInfo.formula);
    formulaInfo.bands = [];
    function layoutSubtree(node) {
      // It looks silly to offer to debug a literal, though it's not harmful.  Open
      // to counterarguments. ~ Matt
      if (node.formula[0] === "lit") {
        node.height = -1;
        return;
      }
      node.ch1 = node.formula.loc.first_column;
      node.ch2 = node.formula.loc.last_column;
      node.height = 0;
      for (let childInfo of node.children) {
        // loc missing for implicit "this" inserted by resolveNavigation; other cases?
        if (childInfo.node.formula.loc != null) {
          layoutSubtree(childInfo.node);
          let isNavigationLhs = (node.formula[0] === "up" || node.formula[0] === "down") && childInfo.paramName === "start";
          if (isNavigationLhs) {
            node.ch1 = childInfo.node.ch2;
          }
          node.height = Math.max(node.height, childInfo.node.height + !isNavigationLhs);
        }
      }
      let top = 4 + template.codeMirror.defaultTextHeight() + NESTED_UNDERLINING_PX_PER_LEVEL * node.height;
      // Tweak for gaps in navigation chains.
      let x1 = template.codeMirror.cursorCoords({
        line: 0,
        ch: node.ch1
      }, "local").left;
      let x2 = template.codeMirror.cursorCoords({
        line: 0,
        ch: node.ch2
      }, "local").left;
      formulaInfo.bands.push({
        node: node,
        selected: false,
        left: x1,
        width: x2 - x1,
        top: top,
        height: NESTED_UNDERLINING_PX_PER_LEVEL
      });
    }
    layoutSubtree(formulaInfo.root);
    formulaInfo.selectedBand = null;
    formulaInfo.haveTraced = false;
    return formulaInfo;
  }

  class TracingView {
    public grid;
    public hot;

    constructor(domElement) {
      // TODO: Add a bunch more settings?
      this.grid = [];
      this.hot = new Handsontable(domElement, {
        readOnly: true,
        readOnlyCellClassName: "",  // Not useful to dim everything.
        cells: (row, col, prop) => {
          let cell = this.grid[row] != null ? this.grid[row][col] : null;
          if (!cell) {
            return {};  // Would like to understand why this is needed...
          }
          return {
            className: cell.cssClasses.join(" ")
          };
        }
      });
    }

    public show(node) {
      let formula = node.formula;
      function formatOutcome(outcome) {
        if (outcome.result != null) {
          // TODO: Display in individual cells so we can support the
          // referent-related features.  Or do we like this better?
          // We could at least base the curly braces on
          // type-checking-level singular-ness once we have it.
          return tsetToTextIgnoreErrors(outcome.result);
        } else {
          return outcome.error;
        }
      }
      // Exclude subformulas with additional bound variables, e.g., filter
      // predicate.  Currently, the only way to debug them is to select them
      // directly.  If we add support for a persistent set of test cases that are
      // heterogeneous in the local variables they define, we can probably remove
      // this restriction.
      //
      // Also throw out implicit "this" again. :/
      let childrenToShow = node.children.filter((childInfo) => (childInfo.node.formula.loc != null) && EJSON.equals(childInfo.node.formula.vars, formula.vars));
      // TODO: Enforce outside-to-inside order ourselves rather than relying on it
      // as a side effect of object iteration order and the way we typecheck
      // formulas.
      let varsAndTypesList = formula.vars.entries().filter((e) => e[1] !== rootColumnId);
      this.grid = [[], []];
      function typeCell(type) {
        return new ViewCell(stringifyTypeForSheet(type), 1, 1, ["rsHeader"].concat(markDisplayClassesForType(type)));
      }
      for (let [name, type] of varsAndTypesList) {
        this.grid[0].push(new ViewCell(name, 1, 1, ["rsHeader"]));
        this.grid[1].push(typeCell(type));
      }
      for (let childInfo of childrenToShow) {
        this.grid[0].push(new ViewCell(childInfo.paramName, 1, 1, ["rsHeader"]));
        this.grid[1].push(typeCell(childInfo.node.formula.type));
      }
      this.grid[0].push(new ViewCell("Result", 1, 1, ["rsHeader"]));
      this.grid[1].push(typeCell(formula.type));
      // XXX It would be cleaner for traceColumnFormula to ensure "traces" was
      // created at least as an empty list on all subformulas, but more work to
      // implement.
      for (let [varValues, outcome] of formula.traces != null ? formula.traces.entries() : null) {
        let line = varsAndTypesList.map(([name, _]) => {
          let val = varValues.get(name).elements()[0];
          return new ViewCell(valueToTextIgnoreErrors(varValues.get(name).type, val));
        });
        for (let childInfo of childrenToShow) {
          let childOutcome = childInfo.node.formula.traces.get(varValues);
          // XXX Would we rather just evaluate cases that weren't originally reached?
          line.push(new ViewCell(childOutcome != null ? formatOutcome(childOutcome) : "(not reached)"));
        }
        line.push(new ViewCell(formatOutcome(outcome)));
        this.grid.push(line);
      }
      let data = this.grid.map((row) => row.map((cell) => cell.value));
      this.hot.loadData(data);
    }

    public destroy() {
      this.hot.destroy();
    }
  }

  function updateTracingView(template) {
    let formulaInfo = newFormulaInfo.get();
    let columnId = changeColumnArgs.get()[0].columnId;
    // Tracing can be slow, so do it only on first demand.  (Longer term, we should
    // optimize it!)
    if (!formulaInfo.haveTraced) {
      traceColumnFormula(formulaInfo.root.formula, columnId);
      formulaInfo.haveTraced = true;
    }
    if (tracingView == null) {
      tracingView = new TracingView(template.find("#TracingView"));  //TracingView'))
    }
    tracingView.show(formulaInfo.selectedBand.node);
  }

  function hasUnsavedData() {
    return newFormulaStr.get() !== origFormulaStr.get();
  }

  function isExpanded() {
    return isFormulaDebuggerOpen.get();
  }

  function stateColumnHasValues(columnId) {
    return Cells.find({
      column: columnId,
      values: {
        $not: {
          $size: 0
        }
      }
    }).count() > 0;
  }

  Template["changeColumn"].events({
    "change #changeColumn-backend": function(event, template) {
      let newFormula = getValueOfSelectedOption(template, "#changeColumn-backend") === "computed" ? DUMMY_FORMULA : null;  //changeColumn-backend') == 'computed'
      let col = getColumn(this.columnId);
      // With these conditions (plus the fact that DUMMY_FORMULA returns empty sets),
      // one can toggle between an empty state column and DUMMY_FORMULA without warnings.
      // If we add the ability to undo this operation, we can probably remove the warnings
      // (except the numErroneousFamilies one, which Matt believes deserves more respect
      // in general).
      if ((newFormula != null) && stateColumnHasValues(this.columnId) && !window.confirm("This will delete all existing cells in the column.  Are you sure?")) {
        selectOptionWithValue(template, "#changeColumn-backend", "state");  //changeColumn-backend', 'state')
        return;
      }
      if ((newFormula == null) && !EJSON.equals(col.formula, DUMMY_FORMULA)) {
        let numErroneousFamilies = Cells.find({
          column: this.columnId,
          error: {
            $exists: true
          }
        }).count();
        if (col.typecheckError != null) {
          let msg = "This will delete your formula.  ";
        } else {
          msg = "This will take a snapshot of the current computed data and delete your formula.";
          if (numErroneousFamilies) {
            msg += `\n\n${numErroneousFamilies} families are currently failing to evaluate; ` + "they will become empty, and you will not be able to distinguish them from " + "families that were originally empty.\n\n";
          } else {
            msg += "  ";
          }
        }
        msg += "Are you sure?";
        if (!window.confirm(msg)) {
          selectOptionWithValue(template, "#changeColumn-backend", "computed");  //changeColumn-backend', 'computed')
          return;
        }
      }
      // Server checks for "state column as child of formula column" error.
      // XXX: Disallow converting keyed objects to state?
      Meteor.call("changeColumnFormula", $$, this.columnId, newFormula, standardServerCallback);
    },
    "change #changeColumn-type": function(event, template) {  //changeColumn-type': (event, template) ->
      let col = getColumn(this.columnId);
      let newSpecifiedType = getValueOfSelectedOption(template, "#changeColumn-type");  //changeColumn-type')
      if (newSpecifiedType === "auto") {
        newSpecifiedType = null;
      }
      // If the new type is text, there is no risk of conversion failure, but I
      // think it's still valuable to explain what's happening.  Right?
      // ~ Matt 2015-12-04
      if ((col.formula == null) && stateColumnHasValues(this.columnId) && !window.confirm("This will attempt to reinterpret existing values as the new type.  " + "Any values that cannot be converted will be deleted.  Proceed?")) {
        selectOptionWithValue(template, "#changeColumn-type", col.specifiedType);  //changeColumn-type', col.specifiedType)
        return;
      }
      Meteor.call("changeColumnSpecifiedType", $$, this.columnId, newSpecifiedType, standardServerCallback);
    },
    "change #changeColumn-referenceDisplayColumn": function(event, template) {  //changeColumn-referenceDisplayColumn': (event, template) ->
      let newReferenceDisplayColumn = getValueOfSelectedOption(template, "#changeColumn-referenceDisplayColumn");  //changeColumn-referenceDisplayColumn')
      if (newReferenceDisplayColumn === "auto") {
        newReferenceDisplayColumn = null;
      }
      Meteor.call("changeColumnReferenceDisplayColumn", $$, this.columnId, newReferenceDisplayColumn, standardServerCallback);
    },
    "click .saveFormula": function(event, template) {
      let contextColumnId = getColumn(this.columnId).parent;
      // canSave ensures that this is defined.
      let formula = newFormulaInfo.get().formula;
      // Canonicalize the string in the field, otherwise the field might stay
      // yellow after successful submission.
      newFormulaStr.set(stringifyFormula(contextColumnId, formula));
      Meteor.call("changeColumnFormula", $$, this.columnId, formula, standardServerCallback);
    },
    "click .revertFormula": (event, template) => {
      newFormulaStr.set(origFormulaStr.get());
    },
    "click .formulaDebuggerToggle": (event, template) => {
      isFormulaDebuggerOpen.set(!isFormulaDebuggerOpen.get());
    },
    "click .formulaBand": function(event, template) {
      // Update selection.
      let formulaInfo = newFormulaInfo.get();
      if (formulaInfo.selectedBand != null) {
        formulaInfo.selectedBand.selected = false;
      }
      formulaInfo.selectedBand = this;
      this.selected = true;
      newFormulaInfo.set(formulaInfo);  // Trigger reactive dependents

      // XXX Might be nice to make this an autorun.
      updateTracingView(template);
    }  //changeColumn-backend': (event, template) ->
  });

  // Needed for the formula div to get added during the "Create formula" handler,
  // rather than sometime later when we get the update from the server.
  Meteor.methods({
    changeColumnFormula: (cc, columnId, formula) => {
      Columns.update(columnId, {
        $set: {
          formula: formula
        }
      });
    }
  });

  export var ActionBar = {
    fullTextToShow: fullTextToShow,
    isLoading: isLoading,
    changeColumnArgs: changeColumnArgs,
    isExpanded: isExpanded,
    hasUnsavedData: hasUnsavedData
  };

}
