namespace Objsheets {

  if (Meteor.isClient) {
    Router.route("/:sheet/apps/ptc/parent", function() {
      this.render("PTC_Parent_login", {
        data: {
          sheet: this.params.sheet
        }
      });
    });
    // That's actually a Person token.  So the URL should be like:
    // /ptc/apps/ptc/parent/5
    // which means that the Person id is ["5"].
    // Future: Hacks to get prettier URLs?
    Router.route("/:sheet/apps/ptc/parent/:clientUser", function() {
      this.render("PTC_Parent", {
        data: {
          sheet: this.params.sheet,
          // XXX: validate (not to mention authentication)
          clientUser: [this.params.clientUser]
        }
      });
    });
    Router.route("/:sheet/apps/split-view/ptc", function() {
      this.render("PTC_Demo", {
        data: {
          sheet: this.params.sheet
        }
      });
    });
    let ptcDemoShowingMasterData = new ReactiveVar(false);
    Template["PTC_Demo"].helpers({
      showingMasterData: () => ptcDemoShowingMasterData.get()
    });
    Template["PTC_Demo"].events({
      "click .demo-ptc-switch-to-view-model": () => {
        ptcDemoShowingMasterData.set(false);
      },
      "click .demo-ptc-switch-to-master-data": () => {
        ptcDemoShowingMasterData.set(true);
      }
    });

    Template["PTC_Parent"].created = function() {
      RelsheetsClient.open(this.data != null ? this.data.sheet : null, "ptc");
    };

    Template["PTC_Parent"].helpers({
      viewData: function() {
        return RelsheetsClient.readSubtree("ParentView", [this.clientUser]);
      }
    });

    Template["PTC_Parent_login"].created = function() {
      RelsheetsClient.open(this.data != null ? this.data.sheet : null);
    };

    Template["PTC_Parent_login"].helpers({
      root: () => RelsheetsClient.readObj(((new View("1").def()) != null ? (new View("1").def()).layout : null) || new Tree(rootColumnId))
    });

    function blur(jbutton) {
      jbutton.width(jbutton.width());
      jbutton.text("∙ ∙ ∙");
    }

    Template["PTC_Parent_enrollment"].events({
      // Future: We could modify the transaction procedures to take objects in
      // the view subtree, instead of the original domain objects, as parameters.
      // This would let us avoid duplicating the write access control checks in the
      // transaction procedures, though it makes it more tedious for users to call
      // transaction procedures programmatically.  For application-defined data
      // integrity constraints, it definitely seems preferable to define them
      // directly and infer the valid choices to show in the view from them (if
      // possible).  Further experience should inform the design here.
      "click .schedule": function(ev) {
        blur($(ev.target));
        RelsheetsClient.call("parentCreateMeeting", {
          clientUser: [this.clientUser],
          enr: [this.enrollment],
          slot: [this.slot]
        }, (error, result) => {
          $(ev.target).text("Schedule");
        });
      },
      "click .cancel": function(ev) {
        blur($(ev.target));
        RelsheetsClient.call("parentCancelMeeting", {
          clientUser: [this.clientUser],
          meeting: this.meeting
        }, (error, result) => {
          $(ev.target).text("Cancel");
        });
      }
    });
  }

  if (Meteor.isServer) {
    RelsheetsServer.procedures("ptc", {
      teacherCreateSlot: {
        params: [["clientUser", "Person"], ["time", "text"]],
        body: "let t = clientUser.Teacher\ncheck t != {}\nlet s = new t.Slot\ns.time := time\ncheck $valid"
      },
      teacherDeleteSlot: {
        params: [["clientUser", "Person"], ["slot", "Person:Teacher:Slot"]],
        body: "check slot.Person = clientUser\ndelete slot\ncheck $valid"
      },
      parentCreateMeeting: {
        params: [["clientUser", "Person"], ["enr", "Class:Section:Enrollment"], ["slot", "Person:Teacher:Slot"]],
        body: "check clientUser in enr.student.parent\nlet m = new $Meeting\nm.enrollment := enr\nm.slot := slot\ncheck $valid"
      },
      parentCancelMeeting: {
        params: [["clientUser", "Person"], ["meeting", "Meeting"]],
        body: "check clientUser in meeting.enrollment.student.parent\ndelete meeting\ncheck $valid"
      },
      // This is just a test of a make statement, not something that actually belongs
      // in the PTC application.
      enroll: {
        params: [["student", "Person:Student"], ["section", "Class:Section"]],
        body: "make section.Enrollment[student]"
      }
    });

    // Future: Add special support for "check $valid"?  But we might want similar
    // functionality for other checks, if the Derailer study is any evidence.
    // Cleanup: Introduce a formula to reduce duplication in enrollment authorization
    // checks?
  }

}
