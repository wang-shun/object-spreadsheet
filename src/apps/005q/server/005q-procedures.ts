namespace Objsheets {

  RelsheetsServer.procedures("005q", {
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
