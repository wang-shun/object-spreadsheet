let instances = {};
class Announce {
  public static get(id) {
    var v;
    return (v = instances[id]) != null ? v : instances[id] = new this(id);
  }
}

let listeners = {
    create: []
  };
class OnDemand extends Announce {
  constructor() {
    for (let cb of listeners.create) {
      try {
        cb.apply(this);
      } catch (e) {
        console.log(e.stack);
      }
    }
  }

  public static onCreate(op) {
    listeners.create.push(op);
  }
}

class ControlContext extends OnDemand {
  constructor() {
    this.scheduled = [];
    this.lock = 0;
    super();
  }

  public static get(id) {
    return id == null ? (Meteor.isServer && CallingContext.get()) || this["default"] : OnDemand.get.call(this, id);
  }

  public run(func : any = () => {}) {
      //Fiber = Npm.require('fibers')     # <-- tried to use Fiber.yield() but got "Fiber is a zombie" error ~~~~
      return CallingContext.set(this, () => {
        if (this.lock) {
          this.scheduled.push(func);  // HACK
        } else {
          try {
            this.lock = 1;
            while (this.scheduled.length > 0) {
              this.scheduled.pop().apply(this);
            }
          } finally {
            this.lock = 0;
          }
          return func.apply(this);
        }
      });
  }

  public "do"(task) {
    this.scheduled.push(task);
  }

  // Convenience method;
  // calls a Meteor method, passing the current cc as first argument

  public call(method, ...args) {
    return Meteor.call.apply(Meteor, [method, this].concat(args));
  }
}

exported({
  Announce: Announce,
  OnDemand: OnDemand,
  ControlContext: ControlContext
});
