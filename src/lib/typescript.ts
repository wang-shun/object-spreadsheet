// Use to suppress TypeScript errors in code for which we have not yet figured
// out the proper typing, so we can get to zero errors and then maintain that as
// we fix the typing in the order we prefer.  This is on par with "implicit
// any". ~ Matt 2016-02-28
//
// This must be outside the Objsheets namespace because it's referenced by some
// typing files.
type fixmeAny = any;
