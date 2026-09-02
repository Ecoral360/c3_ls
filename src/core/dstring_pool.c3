module lsp::core::dstring_pool;

import std::collections::list;

const DSTRING_POOL_INITIAL_CAPACITY @private = 200;

struct DStringPool {
	Allocator allocator;
	List{DString} string_pool;
	sz next_free;
}

fn DStringPool* DStringPool.init(&self, Allocator allocator) {
	self.allocator = allocator;
	self.string_pool.init(allocator, initial_capacity: DSTRING_POOL_INITIAL_CAPACITY);
	return self;
}

fn void DStringPool.reset(&self) {
	self.next_free = 0;
}

fn void DStringPool.free(&self) {
	foreach (s : self.string_pool) {
		s.free();
	}

	self.string_pool.free();
}


<*
 Take the next free slot, cleared and ready to be filled.

 A reference into the list, never a copy: DString is a pointer, and both
 append paths reallocate through it with `*self = ...`, so a copy would
 grow the local handle and leave the pooled entry on the freed block.

 @param [&inout] self
*>
macro DString* next_slot(DStringPool* self) @private {
	if (self.string_pool.size == self.next_free) {
		DString fresh;
		fresh.init(self.allocator);
		self.string_pool.push(fresh);
	}

	DString* slot = self.string_pool.get_ref(self.next_free);
	self.next_free += 1;
	slot.clear();

	return slot;
}

macro String DStringPool.format(&self, String format, ...) {
	DString* s = next_slot(self);
	s.appendf(format, ...$vaarg);
	return s.str_view();
}

<*
 Concatenation, for the formats that are only ever "%s" and literals.

 The C3 formatter walks its output one character at a time through
 utf8_codepoints, which is most of what a completion request spends its
 time on. Appending the pieces is a memcpy each, and the argument list is
 unrolled here so there is no loop over a slice either.
*>
macro String DStringPool.cat(&self, ...) {
	DString* s = next_slot(self);

	$for var $i = 0; $i < $vaarg.len; $i++:
		s.append($vaarg[$i]);
	$endfor

	return s.str_view();
}
