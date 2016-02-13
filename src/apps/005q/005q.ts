if (Meteor.isClient) {
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

  Template.DoubleOhFiveQueue.created = function() {
    Relsheets.open(this.data != null ? this.data.sheet : null, "005q");
  };

  Template.DoubleOhFiveQueueStaff.created = function() {
    Relsheets.open(this.data != null ? this.data.sheet : null, "005q");
  };

  Template.DoubleOhFiveQueue.helpers({
    root: () => Relsheets.read(),
    sortBy: (objs, field) => _.sortBy(objs, (x) => x[field][0]),
    people: (calls) => {
      let count = (calls != null ? calls.length : null) || 0;
      return `${(count === 1 ? "is" : "are")} ` + `${(count === 0 ? "no" : count)} ` + `${(count === 1 ? "person" : "people")}`;
    }
  });

  Template.DoubleOhFiveQueue.events({
    "submit form": (event) => {
      let formData = {
        name: [event.target.name.value],
        issue: [event.target.issue.value],
        location: [event.target.location.value]
      };
      Relsheets.call("enqueue", formData, (error, result) => {
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

  Template.DoubleOhFiveQueueStaff.helpers({
    root: () => Relsheets.read()
  });

  Template.DoubleOhFiveQueueStaff.events({
    "click .pick": function() {
      Relsheets.call("pick", {
        call: this.call,
        user: this.user
      });
    },
    "click .forfeit": function() {
      Relsheets.call("forfeit", {
        call: this.call,
        user: this.user
      });
    },
    "click .done": function() {
      Relsheets.call("done", {
        call: this.call
      });
    }
  });
}

if (Meteor.isServer) {
  Relsheets.procedures("005q", {
    enqueue: {
      params: [["name", "text"], ["issue", "text"], ["location", "text"]],
      body: "let q = new $Call\nq.time := d\"now\"\nq.name := name\nq.location := location\nq.issue := {s : $Skill | s.name = issue}"
    },
    pick: {
      params: [["call", "Call"], ["user", "Staff"]],
      body: "call.assign := user"
    },
    forfeit: {
      params: [["call", "Call"], ["user", "Staff"]],
      body: "call.assign := {}\ncall.forfeit := user"
    },
    done: {
      params: [["call", "Call"]],
      body: "delete call"
    }
  });
}
