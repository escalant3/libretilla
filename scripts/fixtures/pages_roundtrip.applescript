-- Usage: osascript pages_roundtrip.applescript <input.docx> [<output.docx>]
-- Opens <input> in Pages (smoke test: Pages can import it) and prints the word
-- and page counts. If <output> is given, also exports the document as Word.
on run argv
	set inFile to POSIX file (item 1 of argv)
	tell application "Pages"
		activate
		open inFile
		set doc to missing value
		repeat 60 times
			if (count of documents) > 0 then
				set doc to front document
				exit repeat
			end if
			delay 0.5
		end repeat
		if doc is missing value then error "Pages did not open the document"
		set wc to count of words of body text of doc
		set pc to count of pages of doc
		if (count of argv) > 1 then
			export doc to (POSIX file (item 2 of argv)) as Microsoft Word
		end if
		close doc saving no
	end tell
	return "words=" & wc & " pages=" & pc
end run
