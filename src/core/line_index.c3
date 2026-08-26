module lsp::core;

import std::collections::list;

import analyzer::core;

<*
 Maps between byte offsets and line/column Locations for a single file.

 The analyzer used to ship a LineMap for this; the new version reports
 line/column directly on every AST node and token, so this only exists
 for the places that still need raw byte offsets (prefix extraction,
 peeking at the character before the cursor, slicing source text).
*>
struct LineIndex
{
	List{sz} line_starts;
	String text;
}

<*
 @param [&inout] self
*>
fn void LineIndex.init(&self, Allocator allocator, String text)
{
	self.text = text;
	self.line_starts.init(allocator, 64);
	self.line_starts.push(0);

	for (sz i = 0; i < text.len; i++)
	{
		if (text[i] == '\n')
		{
			self.line_starts.push(i + 1);
		}
	}
}

<*
 @param [&inout] self
*>
fn void LineIndex.free(&self)
{
	self.line_starts.free();
}

fn sz LineIndex.line_count(&self) @inline => self.line_starts.len();

<*
 Byte offset of the start of `line`, clamped to the file.
*>
fn sz LineIndex.line_start(&self, sz line)
{
	if (self.line_starts.is_empty()) return 0;
	if (line >= self.line_starts.len()) return self.text.len;
	return self.line_starts[line];
}

<*
 Byte offset for a line/column Location. Both are clamped, so an out of
 range position resolves to the closest valid offset instead of failing.
*>
fn sz LineIndex.offset_of(&self, Location loc)
{
	if (loc.line < 0) return 0;

	sz start = self.line_start((sz)loc.line);
	sz end = self.line_end((sz)loc.line);

	if (loc.column <= 0) return start;

	sz offset = start + (sz)loc.column;
	return offset > end ? end : offset;
}

<*
 Byte offset just past the last character of `line`, not counting the
 line terminator.
*>
fn sz LineIndex.line_end(&self, sz line)
{
	sz next = line + 1;
	if (next >= self.line_starts.len()) return self.text.len;

	sz end = self.line_starts[next];
	// Step back over the terminator so columns stay within the line.
	if (end > 0 && self.text[end - 1] == '\n') end--;
	if (end > 0 && self.text[end - 1] == '\r') end--;
	return end;
}

<*
 Line/column Location for a byte offset.
*>
fn Location LineIndex.location_of(&self, sz offset)
{
	if (offset > self.text.len) offset = self.text.len;

	sz lo = 0;
	sz hi = self.line_starts.len();

	while (lo + 1 < hi)
	{
		sz mid = lo + (hi - lo) / 2;
		if (self.line_starts[mid] <= offset)
		{
			lo = mid;
		}
		else
		{
			hi = mid;
		}
	}

	return { .line = (int)lo, .column = (int)(offset - self.line_starts[lo]) };
}

<*
 Source text covered by `range`, or the empty string if the range does
 not describe a usable slice.
*>
fn String LineIndex.slice(&self, Range range)
{
	sz start = self.offset_of(range.start);
	sz end = self.offset_of(range.end);

	if (start > end || end > self.text.len) return "";
	return self.text[start : end - start];
}
