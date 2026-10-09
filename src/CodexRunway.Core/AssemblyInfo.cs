using System.Runtime.CompilerServices;

// The ported tests exercise the same internals the Swift tests reach with `@testable`.
// Exposing them here is what lets each helper be tested directly instead of only through
// the public surface.
[assembly: InternalsVisibleTo("CodexRunway.Core.Tests")]
