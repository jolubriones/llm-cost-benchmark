Write a PowerShell 5.1-compatible function ConvertTo-TopScores that:
1. Takes a file path to a CSV with columns Name,Score and an optional -Top parameter (default 3).
2. Returns the top N rows by Score (descending), ties broken alphabetically by Name.
3. Throws a clear error if the file does not exist.
Return ONLY the function code.