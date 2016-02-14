// Utility definitions not specific to Relational Spreadsheets.

// Now that we're no longer using custom classes, we might be able to use plain
// JSON, but we've written this already...


  function wrapKey(k) {
    return "map_" + EJSON.stringify(k);
  };
  function unwrapKey(k) {
    return EJSON.parse(k.substr(4));
  };
class EJSONKeyedMap {
    public obj;

  constructor(ents : any = []) {
    // Future: Change to ECMAScript 6 Map when supported by all relevant JS
    // engines and CoffeeScript.
    this.obj = {};
    for (let [k, v] of ents) {
      this.set(k, v);
    }
  }



  public get(k) {
    return this.obj[wrapKey(k)];
  }

  public set(k, v) {
    this.obj[wrapKey(k)] = v;
  }

  public "delete"(k) {
    delete this.obj[wrapKey(k)];
  }

  public size() {
    return _.size(this.obj);
  }

  public keys() {
    var _results;
    _results = [];
    for (let wk in this.obj) {
      _results.push(unwrapKey(wk));
    }
    return _results;
  }

  public entries() {
    var _results;
    _results = [];
    for (let wk in this.obj) {
      let v = this.obj[wk];
      _results.push([unwrapKey(wk), v]);
    }
    return _results;
  }

  public shallowClone() {
    return new EJSONKeyedMap(this.entries());
  }

  public typeName() {
    return "EJSONKeyedMap";
  }

  // Note, this only works if the values are EJSON-compatible.

  public toJSONValue() {
    return EJSON.toJSONValue(this.obj);
  }

  public static fromJSONValue(json) {
    let m = new EJSONKeyedMap();
    m.obj = EJSON.fromJSONValue(json);
    return m;
  }
}
EJSON.addType("EJSONKeyedMap", EJSONKeyedMap.fromJSONValue);
exported({
  EJSONKeyedMap: EJSONKeyedMap
});

class EJSONKeyedSet {
    public map;

  constructor(els : any = []) {
    this.map = new EJSONKeyedMap();
    for (let x of els) {
      this.add(x);
    }
  }

  public has(x) {
    return !!this.map.get(x);
  }

  public hasAll(s) {
    return forall(s.elements(), (x) => this.has(x));
  }

  public add(x) {
    this.map.set(x, true);
  }

  public "delete"(x) {
    this.map["delete"](x);
  }

  public size() {
    return this.map.size();
  }

  public elements() {
    return this.map.keys();
  }

  public shallowClone() {
    return new EJSONKeyedSet(this.elements());
  }

  public typeName = "EJSONKeyedSet";

  public toJSONValue() {
    return this.map.toJSONValue();
  }

  public static fromJSONValue(json) {
    let s = new EJSONKeyedSet();
    s.map = EJSONKeyedMap.fromJSONValue(json);
    return s;
  }
}
EJSON.addType("EJSONKeyedSet", EJSONKeyedSet.fromJSONValue);
exported({
  EJSONKeyedSet: EJSONKeyedSet
});

class EJSONSmallSet {
    public els;

  constructor(els : any = [], _trustMeDistinct : any = false) {
    if (_trustMeDistinct) {
      this.els = els.slice(0);
    } else {
      this.els = [];
      for (let x of els) {
        this.add(x);
      }
    }
  }

  public has(x) {
    return exists(this.els, (y) => EJSON.equals(x, y));
  }

  public hasAll(s) {
    return forall(this.els, (x) => this.has(x));
  }

  public add(x) {
    if (!this.has(x)) {
      this.els.push(x);
    }
  }

  public "delete"(x) {
    this.els = this.els.filter((y) => !EJSON.equals(x, y));
  }

  public elements() {
    return this.els;
  }

  public shallowClone() {
    return new EJSONSmallSet(this.els, true);
  }

  public typeName = "EJSONSmallSet";

  public toJSONValue() {
    return this.els;
  }

  public static fromJSONValue(json) {
    return new EJSONSmallSet(json, true);
  }
}
EJSON.addType("EJSONSmallSet", EJSONSmallSet.fromJSONValue);
exported({
  EJSONSmallSet: EJSONSmallSet
});

//@EJSONKeyedSet = EJSONSmallSet

class EJSONKeyedMapToSet {
    public map;

  constructor() {
    this.map = new EJSONKeyedMap();
  }

  public add(k, v) {
    let s = this.map.get(k);
    if (s == null) {
      s = new EJSONKeyedSet();
      this.map.set(k, s);
    }
    s.add(v);
  }

  public "delete"(k, v) {
    let s = this.map.get(k);
    if (s != null) {
      s["delete"](v);
      if (s.elements().length === 0) {
        this.map["delete"](k);
      }
    }
  }

  public keys() {
    return this.map.keys();
  }

  public has(k, v) {
    var s;
    return ((s = this.map.get(k)) != null) && s.has(v);
  }

  public elementsFor(k) {
    return fallback(this.map.get(k) != null ? this.map.get(k).elements() : null, []);
  }
}
exported({
  EJSONKeyedMapToSet: EJSONKeyedMapToSet
});

class Tree {
  constructor(public root, public subtrees : any = []) {}

  //# applies op to the root of each subtree

  public map(op) {
    return new Tree(op(this.root), this.subtrees.map((s) => s.map(op)));
  }

  public filter(pred) {
    return pred(this.root) ? new Tree(this.root, (this.subtrees.map((s) => s.filter(pred))).filter((x) => x != null)) : null;
  }

  public find(value) {
    return this.findT((n) => n.root === value);
  }

  public findT(pred) {
    var n;
    if (pred(this)) {
      return this;
    } else {
      for (let s of this.subtrees) {
        if ((n = s.findT(pred)) != null) {
          return n;
        }
      }
    }
  }

  public typeName() {
    return "Tree";
  }

  public toJSONValue() {
    return {
      root: this.root,
      subtrees: this.subtrees.map((s) => s.toJSONValue())
    };
  }

  public static fromJSONValue(json) {
    return new Tree(json.root, json.subtrees.map((s) => Tree.fromJSONValue(s)));
  }
}
EJSON.addType("Tree", Tree.fromJSONValue);

class Memo {
    public values;

  constructor() {
    this.values = {};
  }

  public clear() {
    this.values = {};
  }

  public get(key, recompute) {
    var v;
    return (v = this.values[key]) != null ? v : this.values[key] = recompute();
  }
}

// helper functions
function forall(list, pred) {
  for (let x of list) {
    if (!pred(x)) {
      return false;
    }
  }
  return true;
}
function exists(list, pred) {
  for (let x of list) {
    if (pred(x)) {
      return true;
    }
  }
  return false;
}
function without(list, item) {
  return list.filter((x) => x !== item);
}

function zip(...args) {
  let lengthArray = args.map((arr) => arr.length);
  let length = Math.min.apply(Math, lengthArray);
  return _.range(0, length).map((i) => args.map((arr) => arr[i]));
}

function set(x) {
  return new EJSONKeyedSet(x);
}
function T(...args) {
  return (function(func, args, ctor) {
    ctor.prototype = func.prototype;
    var child = new ctor, result = func.apply(child, args);
    return Object(result) === result ? result : child;
  })(Tree, args, function(){});
}

exported({
  set: set,
  Tree: Tree,
  T: T,
  Memo: Memo,
  forall: forall,
  exists: exists,
  without: without,
  zip: zip
});
