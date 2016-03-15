namespace Objsheets {

  Router.route("/:sheet/apps/005q", function() {
    this.render("DoubleOhFiveQueue", {
      data: {
        sheet: this.params.sheet
      }
    });
  });

  Router.route("/:sheet/apps/005q/staff", function() {
    this.render("DoubleOhFiveQueueStaff", {
      data: {
        sheet: this.params.sheet
      }
    });
  });

  Router.route("/:sheet/apps/split-view/005q", function() {
    this.render("DoubleOhFiveQueue_Demo", {
      data: {
        sheet: this.params.sheet
      }
    });
  });

  Template["DoubleOhFiveQueue"].created = function() {
    RelsheetsClient.open(this.data != null ? this.data.sheet : null, "005q");
  };

  Template["DoubleOhFiveQueueStaff"].created = function() {
    RelsheetsClient.open(this.data != null ? this.data.sheet : null, "005q");
  };

  Template["DoubleOhFiveQueue"].helpers({
    root: () => RelsheetsClient.read(),
    sortBy: (objs: fixmeAny, field: fixmeAny) => _.sortBy(objs, (x: fixmeAny) => x[field][0]),
    people: (calls: fixmeAny) => {
      let count = (calls != null ? calls.length : null) || 0;
      return `${(count === 1 ? "is" : "are")} ` + `${(count === 0 ? "no" : count)} ` + `${(count === 1 ? "person" : "people")}`;
    }
  });

  Template["DoubleOhFiveQueue"].events({
    "submit form": (event: fixmeAny) => {
      let formData = {
        name: [event.target.name.value],
        issue: [event.target.issue.value],
        location: [event.target.location.value]
      };
      RelsheetsClient.call("enqueue", formData, (error: fixmeAny, result: fixmeAny) => {
        if (error == null) {
          event.target.reset();
        }
      });
      $(".help.button").addClass("disabled");
      return false;
    },
    "keyup #name, #topic": () => {  //name, #topic': ->
      let helpButton = $(".help.button");
      if ($("#name").val()) {  //name').val()
        helpButton.removeClass("disabled");
      } else {
        helpButton.addClass("disabled");
      }
    }
  });

  Template["DoubleOhFiveQueueStaff"].helpers({
    root: () => RelsheetsClient.read()
  });

  Template["DoubleOhFiveQueueStaff"].events({
    "click .pick": function() {
      RelsheetsClient.call("pick", {
        call: this.call,
        user: this.user
      });
    },
    "click .forfeit": function() {
      RelsheetsClient.call("forfeit", {
        call: this.call,
        user: this.user
      });
    },
    "click .done": function() {
      RelsheetsClient.call("done", {
        call: this.call
      });
    }
  });

}
