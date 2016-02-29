namespace Objsheets {

  Router.route("/:sheet/apps/maid", function() {
    this.render("MilkMaid", {
      data: {
        sheet: this.params.sheet
      }
    });
  });

  Router.route("/:sheet/apps/split-view/milk", function() {
    this.render("MilkMaid_Demo", {
      data: {
        sheet: this.params.sheet
      }
    });
  });

  Template["MilkMaid"].created = function() {
    RelsheetsClient.open(this.data != null ? this.data.sheet : null, "milk");
  };

  Template["MilkMaid"].helpers({
    milk: () => RelsheetsClient.read(),
    label: function() {
      return this["name"];
    },
    isNext: function() {
      return this.isNext[0];
    },
    sameAs: function(o) {
      return EJSON.equals(this.qCellId, o[0] != null ? o[0].qCellId : null);
    },
    stringify: (a) => JSON.stringify(a)
  });

  Template["MilkMaid"].events({
    "click button": function() {
      RelsheetsClient.call("supply", {
        me: this
      });
    },
    "click .marking": function() {
      RelsheetsClient.call("request", {
        level: this
      });
    }
  });

}
