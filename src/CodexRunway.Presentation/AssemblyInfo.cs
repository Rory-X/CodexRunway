using System.Runtime.CompilerServices;

// Unit tests exercise the parsing helpers directly — tag normalization, version comparison,
// the quota thresholds — rather than only through the public surface. Testing "1.10.0 is newer
// than 1.9.0" through a full feed fixture would obscure what is actually being checked.
[assembly: InternalsVisibleTo("CodexRunway.Presentation.Tests")]
