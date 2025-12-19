
// don't use this until it's set up as a linked list so you can immediately access free spans
// for multiple adjacent spans, you will still iterate through the free list and for each span you
// will check their N adjacent blocks
// once you find one that had the required amount of adjacencies you will use the blocks prev/next values
// to pop them out of the free list and apend them specifically after the initial adjacent span on the
// claimed list
// so this way when you free the one single claimed span from the allocator you will just put it back as
// contiguous memory

#module_parameters(DEBUG := false);

ARENA_BLOCK_SIZE :: 16384 * 1024;

ArenaAllocator :: struct {
    blocks_32: [..] [] [32] u8;
    blocks_256: [..] [] [256] u8;
    blocks_4096: [..] [] [4096] u8;
    blocks_16384: [..] [] [16384] u8;

    available_32: [..] s32;
    available_256: [..] s32;
    available_4096: [..] s32;
    available_16384: [..] s32;

    internal_allocator: Allocator;
}

get_arena_allocator :: () -> Allocator {
    arena := New(ArenaAllocator);

    remember_allocators(*arena.blocks_32);
    remember_allocators(*arena.blocks_256);
    remember_allocators(*arena.blocks_4096);
    remember_allocators(*arena.blocks_16384);

    remember_allocators(*arena.available_32);
    remember_allocators(*arena.available_256);
    remember_allocators(*arena.available_4096);
    remember_allocators(*arena.available_16384);

    allocate_blocks(*arena.blocks_32, *arena.available_32);
    allocate_blocks(*arena.blocks_256, *arena.available_256);
    allocate_blocks(*arena.blocks_4096, *arena.available_4096);
    allocate_blocks(*arena.blocks_16384, *arena.available_16384);

    arena.internal_allocator = context.allocator;

    result: Allocator;
    result.proc = arena_allocator_proc;
    result.data = arena;

    return result;
}

deinit_arena_allocator :: (allocator: Allocator) {
    arena := cast(*ArenaAllocator) allocator.data;
    assert(!!arena);

    deinit(arena);
    free(arena);
}

#scope_file

alloc :: (arena: *ArenaAllocator, size: int) -> *void {
    if size <= 32 {
        return claim_available(*arena.blocks_32, *arena.available_32);
    } else if size <= 256 {
        return claim_available(*arena.blocks_256, *arena.available_256);
    } else if size <= 4096 {
        return claim_available(*arena.blocks_4096, *arena.available_4096);
    } else if size <= 16384 {
        return claim_available(*arena.blocks_16384, *arena.available_16384);
    } else {
        return alloc(size,, arena.internal_allocator);
    }
}

free :: (arena: *ArenaAllocator, data: *void) {
    for block: arena.blocks_32 {
        if data >= block.data && data < block.data + block.count {
            free(block, it_index, *arena.available_32, data);
            return;
        }
    }
    for block: arena.blocks_256 {
        if data >= block.data && data < block.data + block.count {
            free(block, it_index, *arena.available_256, data);
            return;
        }
    }
    for block: arena.blocks_4096 {
        if data >= block.data && data < block.data + block.count {
            free(block, it_index, *arena.available_4096, data);
            return;
        }
    }
    for block: arena.blocks_16384 {
        if data >= block.data && data < block.data + block.count {
            free(block, it_index, *arena.available_16384, data);
            return;
        }
    }

    free(data,, arena.internal_allocator);
}

free :: (block: [] [$N] u8, block_index: int, available: *[..] s32, data: *void) {
    span_count := ARENA_BLOCK_SIZE / N;

    byte_offset := cast(s64) (cast(u64) data - cast(u64) block.data);
    span_index := byte_offset / N;
    index := block_index * span_count + byte_offset / N;

    assert(span_index >= 0 && span_index < block.count);
    assert(byte_offset >= 0 && byte_offset < block.count * N);

    array_add(available, cast(s32) index);
}

claim_available :: (blocks: *[..] [] [$N] u8, available: *[..] s32) -> *void {
    if available.count == 0 {
        allocate_blocks(blocks, available);
        assert(available.count > 0, "Could not allocate new block for some reason.\n");
    }

    span_count := ARENA_BLOCK_SIZE / N;

    next_available := available.*[available.count - 1];
    available.count -= 1;

    block_index := next_available / span_count;
    span_index := next_available % span_count;

    return *(blocks.*[block_index][span_index]);
}

resize :: (arena: *ArenaAllocator, data: *void, size: int, old_size: int) -> *void {
    allocated := alloc(arena, size);
    smemcpy(allocated, data, min(size, old_size));
    free(arena, data);

    return allocated;
}

is_this_yours :: (arena: *ArenaAllocator, data: *void) -> bool {
    for block: arena.blocks_32 {
        if data >= block.data && data < block.data + block.count {
            return true;
        }
    }
    for block: arena.blocks_256 {
        if data >= block.data && data < block.data + block.count {
            return true;
        }
    }
    for block: arena.blocks_4096 {
        if data >= block.data && data < block.data + block.count {
            return true;
        }
    }
    for block: arena.blocks_16384 {
        if data >= block.data && data < block.data + block.count {
            return true;
        }
    }
    return false;
}

allocate_blocks :: (blocks: *[..] [] [$N] u8, available: *[..] s32) {
    block_count :: ARENA_BLOCK_SIZE / N;

    block := NewArray(block_count, [N] u8,, blocks.allocator);

    index_start := blocks.count * block_count;
    array_reserve(available, available.count + block_count);
    for i: 0..block_count - 1 {
        array_add(available, cast(s32) (index_start + i));
    }

    array_add(blocks, block);
}

arena_allocator_proc :: (mode: Allocator_Mode, requested_size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void #no_abc #no_aoc {
    arena := cast(*ArenaAllocator) allocator_data;

    if #complete mode == {
        case .FREE;
            if arena {
                free(arena, old_memory);
            }
            return null;

        case .RESIZE;
            return resize(arena, old_memory, requested_size, old_size);

        case .ALLOCATE;
            return alloc(arena, requested_size);

        case .STARTUP; #through;
        case .SHUTDOWN;
            assert(false, "Arena allocator does not support startup/shutdown. I think this is for global allocators?\n");
            return null;

        case .THREAD_START; #through;
        case .THREAD_STOP;
            assert(false, "Arena allocator does not support multiple threads. But it could.\n");
            return null;

        case .CREATE_HEAP; #through;
        case .DESTROY_HEAP;
            assert(false, "Arena allocator does not support heap lifecycle because I don't understand it and also don't think it's needed.\n");
            return null;

        case .IS_THIS_YOURS;
            result := is_this_yours(arena, old_memory);
            return cast(*void) cast(s64) result;

        case .CAPS;
            if old_memory { (cast(*string) old_memory).* = CAPS_VERSION_STRING; }
            return cast(*void) (Allocator_Caps.HINT_I_AM_A_GENERAL_HEAP_ALLOCATOR|.IS_THIS_YOURS|.ACTUALLY_RESIZE|.FREE);

        case;
            assert(false, "Invalid or corrupt mode passed to arena allocator. %\n", mode);
            return null;
    }
}

smemcpy :: inline (dest: *void, source: *void, count: s64) #c_call {
    if dest == source || count <= 0 {
        return;
    }

    #if OS == .LINUX {
        libc :: #system_library "libc";
        memmove :: (dst: *void, src: *void, size: s64) -> *void #foreign libc "memmove";
    } else #if OS == .WINDOWS {
        Crt :: #library,system "msvcrt";
        memmove :: (dst: *void, src: *void, size: s64) -> *void #foreign Crt "memmove";
    } else {
        #assert "This OS isn't supported for smemcpy.";
    }

    dest_end := dest + count;
    source_end := source + count;

    if dest_end <= source || source_end <= dest {
        memcpy(dest, source, count);
    } else {
        memmove(dest, source, count);
    }
}

CAPS_VERSION_STRING :: "Arena allocator for fast small allocations.";

seconds_since_init :: () -> float64 {
    return to_float64_seconds(current_time_consensus());
}

#import "Basic";

