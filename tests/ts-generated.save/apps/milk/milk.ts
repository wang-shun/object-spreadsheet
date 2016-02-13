if (Meteor.isClient) {
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

  Template.MilkMaid.created = function() {
    Relsheets.open(this.data != null ? this.data.sheet : null, "milk");
  };

  Template.MilkMaid.helpers({
    milk: () => Relsheets.read(),
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

  Template.MilkMaid.events({
    "click button": function() {
      Relsheets.call("supply", {
        me: this
      });
    },
    "click .marking": function() {
      Relsheets.call("request", {
        level: this
      });
    }
  });
}

if (Meteor.isServer) {
  Relsheets.procedures("milk", {
    supply: {
      params: [["me", "Team"]],
      body: "$Gauge.reading := {l: $Gauge.Level | l.name = \"Full\"}\nme.quota := me.quota - 2\nif (me.quota <= 0) {\n  me.lastTime := d\"now\" \n  $Team.quota := 4      # reset all quotas\n  let m = new $Message\n  m.`to` := {c: $Team | c.isNext}\n  m.subject := \"Heads Up: You Are Next\"\n}"  // reset all quotas
    },
    request: {
      params: [["level", "Gauge:Level"]],
      body: "$Gauge.reading := level\nlet m = new $Message\nm.`to` := {c: $Team | c.isNext}\nm.subject := \"Milk Level Alert\" "
    },
    // We can change the semantics of the button request here as desired.
    dashButtonRequest: {
      params: [],
      body: "$Gauge.reading := {l: $Gauge.Level | l.name = \"Empty\"}\nlet m = new $Message\nm.`to` := {c: $Team | c.isNext}\nm.subject := \"Milk Level Alert\" "
    }
  });
}
