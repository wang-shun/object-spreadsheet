if (Meteor.isClient) {
  Router.route("/:sheet/apps/beta", function() {
    this.render("DearBeta", {
      data: {
        sheet: this.params.sheet
      }
    });
  });
  Router.route("/:sheet/apps/split-view/beta", function() {
    this.render("DearBeta_Demo", {
      data: {
        sheet: this.params.sheet
      }
    });
  });

  Template.DearBeta.created = function() {
    Relsheets.open(this.data != null ? this.data.sheet : null, "beta");
  };

  Template.DearBeta.helpers({
    files: () => {
      let obj = Relsheets.read();
      return obj.File;
    }
  });

  Template.DearBeta.events({
    "click .Request .up": function() {
      Relsheets.call("requestUp", {
        at: [this.Request.qFamilyId.cellId]
      });
    },
    "click .Request .down": function() {
      Relsheets.call("requestDown", {
        at: [this.qCellId.cellId]
      });
    },
    "click .Hint .up": function() {
      Relsheets.call("hintUp", {
        at: [this.Vote.qFamilyId.cellId]
      });
    },
    "click .Hint .down": function() {
      Relsheets.call("hintDown", {
        at: [this.qCellId.cellId]
      });
    },
    "click .Hint .del": function() {
      Relsheets.call("hintDel", {
        at: [this.qCellId.cellId]
      });
    },
    "submit form": function(event) {
      Relsheets.call("hintAdd", {
        at: [this.Hint.qFamilyId.cellId],
        text: [event.target.text.value]
      }, (error, result) => {
        if (error == null) {
          event.target.reset();
        }
      });
      return false;
    }
  });
}

if (Meteor.isServer) {
  Relsheets.procedures("beta", {
    requestUp: {
      params: [["at", "File:Node:Time"]],
      body: "new at.Request"
    },
    requestDown: {
      params: [["at", "File:Node:Time"]],
      body: "delete oneOf(at.Request)"
    },
    hintUp: {
      params: [["at", "File:Node:Time:Hint"]],
      body: "new at.Vote"
    },
    hintDown: {
      params: [["at", "File:Node:Time:Hint"]],
      body: "delete oneOf(at.Vote)"
    },
    hintAdd: {
      params: [["at", "File:Node:Time"], ["text", "text"]],
      body: "let h = new at.Hint\nh.body := text"
    },
    hintDel: {
      params: [["at", "File:Node:Time:Hint"]],
      body: "delete at"
    }
  });
}
