// check-implicit-any magic comment: noImplicitAny

// Utility definitions not specific to Relational Spreadsheets.

// Now that we're no longer using custom classes, we might be able to use plain
// JSON, but we've written this already...

namespace Objsheets {

  // In principle, what we'd like is "V can be anything, but EJSONKeyedMap is
  // only an EJSON.CustomType if V extends EJSONable".  But we can't express
  // this precisely, and we only use this with V extends EJSONable anyway.
  export class EJSONKeyedMap<K extends EJSONable, V extends EJSONable> {
    private obj: {[wrappedKey: string]: V};

    private wrapKey(k: K): string {
      return "map_" + EJSON.stringify(k);
    };
    private unwrapKey(k: string): K {
      return EJSON.parse(k.substr(4));
    };

    constructor(ents: [K, V][] = []) {
      // Future: Change to ECMAScript 6 Map when supported by all relevant JS
      // engines and CoffeeScript.
      this.obj = {};
      for (let [k, v] of ents) {
        this.set(k, v);
      }
    }

    public get(k: K): V {
      return this.obj[this.wrapKey(k)];
    }

    public set(k: K, v: V): void {
      this.obj[this.wrapKey(k)] = v;
    }

    public "delete"(k: K): void {
      delete this.obj[this.wrapKey(k)];
    }

    public size(): number {
      return _.size(this.obj);
    }

    public keys(): K[] {
      let keys: K[] = [];
      for (let wk in this.obj) {
        keys.push(this.unwrapKey(wk));
      }
      return keys;
    }

    public entries(): [K, V][] {
      let entries: [K, V][] = [];
      for (let wk in this.obj) {
        let v = this.obj[wk];
        entries.push([this.unwrapKey(wk), v]);
      }
      return entries;
    }

    public shallowClone(): EJSONKeyedMap<K, V> {
      return new EJSONKeyedMap(this.entries());
    }

    public typeName(): string {
      return "EJSONKeyedMap";
    }

    public toJSONValue(): JSONable {
      return EJSON.toJSONValue(this.obj);
    }

    public static fromJSONValue(json: any): EJSONKeyedMap<any, any> {
      let m = new EJSONKeyedMap<any, any>();
      m.obj = EJSON.fromJSONValue(json);
      return m;
    }
  }
  EJSON.addType("EJSONKeyedMap", EJSONKeyedMap.fromJSONValue);

  export class EJSONKeyedSet<E extends EJSONable> {
    private map: EJSONKeyedMap<E, boolean>;

    constructor(els: E[] = []) {
      this.map = new EJSONKeyedMap<E, boolean>();
      for (let x of els) {
        this.add(x);
      }
    }

    public has(x: E): boolean {
      return !!this.map.get(x);
    }

    public hasAll(s: EJSONKeyedSet<E>): boolean {
      return forall(s.elements(), (x) => this.has(x));
    }

    public add(x: E): void {
      this.map.set(x, true);
    }

    public "delete"(x: E): void {
      this.map["delete"](x);
    }

    public size(): number {
      return this.map.size();
    }

    public elements(): E[] {
      return this.map.keys();
    }

    public shallowClone(): EJSONKeyedSet<E> {
      return new EJSONKeyedSet(this.elements());
    }

    public typeName(): string {
      return "EJSONKeyedSet";
    }

    public toJSONValue(): JSONable {
      return this.map.toJSONValue();
    }

    public static fromJSONValue(json: any): EJSONKeyedSet<any> {
      let s = new EJSONKeyedSet<any>();
      s.map = EJSONKeyedMap.fromJSONValue(json);
      return s;
    }
  }
  EJSON.addType("EJSONKeyedSet", EJSONKeyedSet.fromJSONValue);

  export class Tree<T extends EJSONable> {
    constructor(public root: T, public subtrees: Tree<T>[] = []) {}

    public size(): number {
      return this.subtrees.reduce((x,y) => x+y.size(), 1);
    }
    
    public forEach(op: (x: T) => void) {
      op(this.root);
      this.subtrees.forEach((s) => s.forEach(op));
    }
    
    /**
     * applies op to the root of each subtree
     */
    public map<S extends EJSONable>(op: (x: T) => S): Tree<S> {
      return new Tree(op(this.root), this.subtrees.map((s) => s.map(op)));
    }

    public filter(pred: (x: T) => boolean): Tree<T> {
      return pred(this.root) ? new Tree(this.root, (this.subtrees.map((s) => s.filter(pred))).filter((x) => x != null)) : null;
    }

    public find(value: T): Tree<T> {
      return this.findT((n) => n.root === value);
    }

    public findT(pred: (t: Tree<T>) => boolean): Tree<T> {
      if (pred(this)) {
        return this;
      } else {
        for (let s of this.subtrees) {
          let n = s.findT(pred);
          if (n != null) {
            return n;
          }
        }
      }
    }

    public toString(): string {
      if (this.subtrees.length > 0)
        return `${this.root.toString()}{${this.subtrees.map((s) => s.toString()).join(", ")}}`
      else
       return this.root.toString()
    }
    
    public typeName(): string {
      return "Tree";
    }

    public toJSONValue(): JSONable {
      return {
        root: EJSON.toJSONValue(this.root),
        subtrees: this.subtrees.map((s) => s.toJSONValue())
      };
    }

    public static fromJSONValue(json: any) {
      return new Tree(json.root, json.subtrees.map((s: any) => Tree.fromJSONValue(s)));
    }
  }
  EJSON.addType("Tree", Tree.fromJSONValue);

  export class Memo<V> {
    private values: {[k: string]: V};

    constructor() {
      this.values = {};
    }

    public clear(): void {
      this.values = {};
    }

    public get(key: string, recompute: () => V): V {
      let v = this.values[key];
      return v != null ? v : this.values[key] = recompute();
    }
  }

  // helper functions
  export function forall<T>(list: T[], pred: (x: T) => boolean): boolean {
    for (let x of list) {
      if (!pred(x)) {
        return false;
      }
    }
    return true;
  }
  export function exists<T>(list: T[], pred: (x: T) => boolean): boolean {
    for (let x of list) {
      if (pred(x)) {
        return true;
      }
    }
    return false;
  }
  export function without<T>(list: T[], item: T): T[] {
    return list.filter((x) => x !== item);
  }

  // We only call this with two arguments, so let's use the simpler
  // implementation for now. ~ Matt 2016-03-14
  export function zip<A, B>(arr1: A[], arr2: B[]): [A, B][] {
    let length = Math.min(arr1.length, arr2.length);
    // TypeScript does not infer the type argument of "map" from the contextual
    // return type.
    // https://github.com/Microsoft/TypeScript/issues/1212
    return _.range(0, length).map<[A, B]>((i) => [arr1[i], arr2[i]]);
  }

  export function set<E extends EJSONable>(x?: E[]): EJSONKeyedSet<E> {
    return new EJSONKeyedSet(x);
  }
  export function T<T extends EJSONable>(root: T, subtrees?: Tree<T>[]) {
    return new Tree(root, subtrees);
  }

}
