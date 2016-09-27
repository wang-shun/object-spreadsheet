namespace Objsheets {

  Router.route("/:sheet/apps/maid", function(this: fixmeAny) {
    this.render("MilkMaid", {
      data: {
        sheet: this.params.sheet
      }
    });
  });

  Router.route("/:sheet/apps/split-view/milk", function(this: fixmeAny) {
    this.render("MilkMaid_Demo", {
      data: {
        sheet: this.params.sheet
      }
    });
  });

  Template["MilkMaid"].created = function(this: fixmeAny) {
    RelsheetsClient.open(this.data != null ? this.data.sheet : null, "milk");
  };

  Template["MilkMaid"].helpers({
    milk: () => RelsheetsClient.read(),
    label: function(this: fixmeAny) {
      return this["name"];
    },
    isNext: function(this: fixmeAny) {
      return this.isNext[0];
    },
    sameAs: function(this: fixmeAny, o: fixmeAny) {
      return EJSON.equals(this.qCellId, o[0] != null ? o[0].qCellId : null);
    },
    stringify: (a: fixmeAny) => JSON.stringify(a)
  });

  Template["MilkMaid"].events({
    "click button": function(this: fixmeAny) {
      RelsheetsClient.call("supply", {
        me: this
      });
    },
    "click .marking": function(this: fixmeAny) {
      RelsheetsClient.call("request", {
        level: this
      });
    }
  });

}
