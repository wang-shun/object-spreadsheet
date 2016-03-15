namespace Objsheets {

  export class View {
    constructor(public id: fixmeAny) {}

    public def() {
      return this.id != null ? Views.findOne(this.id) || {
        layout: new Tree(rootColumnId)
      } : {
        layout: View.rootLayout()
      };
    }

    public addColumn(columnId: fixmeAny, own: fixmeAny = false) {
      let def = this.def();
      let parentId = Columns.findOne(columnId) != null ? Columns.findOne(columnId).parent : null;
      if (parentId != null) {
        let layoutTree = def.layout;
        let layoutSubtree = layoutTree.find(parentId);
        if (layoutSubtree != null) {
          layoutSubtree.subtrees.push(new Tree(columnId));
          Views.upsert(this.id, def);
        }
        if (own) {
          Columns.update(columnId, {
            $set: {
              view: this.id
            }
          });
        }
      }
    }

    public removeColumn(columnId: fixmeAny) {
      let def = this.def();
      def.layout = def.layout.filter((x: fixmeAny) => x !== columnId);
      Views.update(this.id, def);
    }

    public reorderColumn(columnId: fixmeAny, newIndex: fixmeAny) {
      let def = this.def();
      let parentId = Columns.findOne(columnId) != null ? Columns.findOne(columnId).parent : null;
      if (parentId != null) {
        let layoutTree = def.layout;
        let layoutSubtreeParent = layoutTree.find(parentId);
        let layoutSubtreeChild = layoutTree.find(columnId);
        if ((layoutSubtreeParent != null) && (layoutSubtreeChild != null)) {
          layoutSubtreeParent.subtrees = layoutSubtreeParent.subtrees.filter((x: fixmeAny) => x.root !== columnId);
          layoutSubtreeParent.subtrees.splice(newIndex, 0, layoutSubtreeChild);
          Views.update(this.id, {
            $set: {
              layout: layoutTree
            }
          });
          // Cannot use upsert or update(@id, def) if calling from client
          // "update failed: Access denied. Upserts not allowed in a restricted collection."
        }
      }
    }

    public static rootLayout() {
      return this.drillDown(rootColumnId).filter((x) => this.ownerOf(x) == null);
    }

    public static drillDown(startingColumnId: fixmeAny) {
      let children = (Columns.findOne(startingColumnId) != null ? Columns.findOne(startingColumnId).children : null) || [];
      return new Tree(startingColumnId, children.map((child: fixmeAny) => this.drillDown(child)));
    }

    public static ownerOf(columnId: fixmeAny) {
      return Columns.findOne(columnId) != null ? Columns.findOne(columnId).view : null;
    }

    public static removeColumnFromAll(columnId: fixmeAny) {
      Views.find().forEach((view: fixmeAny) => {
        if (view.layout.find(columnId) != null) {
          new View(view._id).removeColumn(columnId);
        }
      });
    }
  }

}
