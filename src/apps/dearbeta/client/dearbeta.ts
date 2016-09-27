namespace Objsheets {

  Router.route("/:sheet/apps/beta", function(this: fixmeAny) {
    this.render("DearBeta", {
      data: {
        sheet: this.params.sheet
      }
    });
  });
  Router.route("/:sheet/apps/split-view/beta", function(this: fixmeAny) {
    this.render("DearBeta_Demo", {
      data: {
        sheet: this.params.sheet
      }
    });
  });

  Template["DearBeta"].created = function(this: fixmeAny) {
    RelsheetsClient.open(this.data != null ? this.data.sheet : null, "beta");
  };

  Template["DearBeta"].helpers({
    files: () => {
      let obj = RelsheetsClient.read();
      return obj.File;
    }
  });

  Template["DearBeta"].events({
    "click .Request .up": function(this: fixmeAny) {
      RelsheetsClient.call("requestUp", {
        at: [this.Request.qFamilyId.cellId]
      });
    },
    "click .Request .down": function(this: fixmeAny) {
      RelsheetsClient.call("requestDown", {
        at: [this.qCellId.cellId]
      });
    },
    "click .Hint .up": function(this: fixmeAny) {
      RelsheetsClient.call("hintUp", {
        at: [this.Vote.qFamilyId.cellId]
      });
    },
    "click .Hint .down": function(this: fixmeAny) {
      RelsheetsClient.call("hintDown", {
        at: [this.qCellId.cellId]
      });
    },
    "click .Hint .del": function(this: fixmeAny) {
      RelsheetsClient.call("hintDel", {
        at: [this.qCellId.cellId]
      });
    },
    "submit form": function(this: fixmeAny, event: fixmeAny) {
      RelsheetsClient.call("hintAdd", {
        at: [this.Hint.qFamilyId.cellId],
        text: [event.target.text.value]
      }, (error: fixmeAny, result: fixmeAny) => {
        if (error == null) {
          event.target.reset();
        }
      });
      return false;
    }
  });

}
