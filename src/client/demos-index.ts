namespace Objsheets {

  function indexPathForExamplesNamePrefix(examplesNamePrefix: fixmeAny) {
    // Based on the pathFor template helper, which doesn't appear to have an
    // equivalent accessible from code. :(
    return (<fixmeAny>Router.routes)["index"].path(null, {
      query: {
        examplesNamePrefix: examplesNamePrefix
      }
    });
  }

  // XXX docs.meteor.com claims that Meteor.settings.public should always exist,
  // but it didn't in my test.  docs.meteor.com is for the latest version of
  // Meteor, so retest after we upgrade. ~ Matt 2015-12-15
  let indexMultiuser = Meteor.settings != null ? Meteor.settings["public"] != null ? Meteor.settings["public"].indexMultiuser : null : null;

  Router.route("/", (function(this: fixmeAny) {
    let examplesNamePrefix = this.params.query.examplesNamePrefix;
    // Only redirect if examplesNamePrefix was unset.  Don't go wild if the user just
    // clears the input field.
    if (indexMultiuser && (examplesNamePrefix == null)) {
      Router.go(indexPathForExamplesNamePrefix(Random.id()));
    } else {
      if (examplesNamePrefix == null) {
        examplesNamePrefix = "";
      }
      this.render("Index", {
        data: {
          examplesNamePrefix: examplesNamePrefix
        }
      });
    }
  }), <fixmeAny>{
    name: "index",
    onAfterAction: () => {
      document.title = "Object Spreadsheets";
    }
  });

  Template["Index"].helpers({
    // Since we aren't restricting what domain names can point to our hosted demo
    // servers, it's easiest to just base this on the URL of the current page.  To
    // use Meteor.absoluteUrl, we'd have to set the ROOT_URL environment variable
    // on each server.
    //
    // XXX: Is there a library that does the following in a more robust way?
    absUrl: (path: fixmeAny) => location.protocol + "//" + location.host + path,
    indexMultiuser: () => indexMultiuser,
    newSheetName: () => Session.get("newSheetName")
  });

  Template["Index_ConditionalExampleLink"].helpers({
    examplesNamePrefixWithDot: () => {
      let examplesNamePrefix = (<fixmeAny>Template.parentData()).examplesNamePrefix;
      return examplesNamePrefix ? examplesNamePrefix + "." : "";
    },
    shouldEnableExampleLinks: () => {
      let examplesNamePrefix = (<fixmeAny>Template.parentData()).examplesNamePrefix;
      return !indexMultiuser || examplesNamePrefix;
    }
  });

  Template["Index"].events({
    "input #examplesNamePrefix": (event: fixmeAny, template: fixmeAny) => {
      Router.go(indexPathForExamplesNamePrefix(event.target.value));
    },
    "input #newSheetName": (event: fixmeAny, template: fixmeAny) => {  //newSheetName': (event, template) ->
      Session.set("newSheetName", event.target.value);
    },
    "click #newSheetGo": (event: fixmeAny, template: fixmeAny) => {  //newSheetGo': (event, template) ->
      Router.go("/" + Session.get("newSheetName"));
    },
    "keypress #newSheetName": (event: fixmeAny, template: fixmeAny) => {  //newSheetName': (event, template) ->
      if (event.which === 13) {
        Router.go("/" + Session.get("newSheetName"));
      }
    }  //examplesNamePrefix': (event, template) ->
  });

}
