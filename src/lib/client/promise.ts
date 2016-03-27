namespace Objsheets {

  export function promiseThenCallback<R>(promise: Promise<R>, callback: MeteorCallback<R>): void {
    promise.then(
      (result) => { callback(null, result); },
      (error) => { callback(error, null); });
  }

  // There are libraries we could use, like maybe
  // https://github.com/rain1017/async-lock, but for now I think it's easier to
  // use my own. ~ Matt 2016-03-26
  export class OneAtATime {
    private busy = false;
    private queue: (() => void)[] = [];

    private workItemFinished(): void {
      this.busy = false;
      this.step();
    }

    private step(): void {
      if (!this.busy && this.queue.length > 0) {
        let nextWorkItem = this.queue.shift();
        this.busy = true;
        nextWorkItem();
      }
    }

    public run<R>(f: () => Promise<R>): Promise<R> {
      return new Promise<R>((resolve, reject) => {
        let workItem = () => f().then((result) => {
          resolve(result);
          this.workItemFinished();
        }, (error) => {
          reject(error);
          this.workItemFinished();
        });
        this.queue.push(workItem);
        this.step();
      });
    }
  }
}
