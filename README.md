# Set-Associative Cache (SystemVerilog & Chisel)

## Project Overview

This project implements a 4-way Set-Associative Cache with a Pseudo-LRU (Approximate LRU) replacement policy.

The cache is designed and implemented in:

- SystemVerilog (SV)
- Chisel (Scala-based HDL)

The design models a simplified processor-memory hierarchy suitable for computer architecture and digital design studies.

---

## Cache Specifications

| Parameter | Value |
|------------|--------|
| Main Memory Size | 1 MB |
| Cache Size | 64 KB |
| Cache Line Size | 32 Bytes |
| Associativity | 4-way Set Associative |
| Replacement Policy | Pseudo-LRU (Tree-based Approximate LRU) |

---

## Cache Organization

### Address Breakdown

Main Memory = 1 MB = 2^20 bytes  
Cache Size = 64 KB = 2^16 bytes  
Block Size = 32 bytes = 2^5 bytes  
Associativity = 4 ways per set  

Number of cache lines:

64 KB / 32 B = 2048 lines

Number of sets:

2048 / 4 = 512 sets  
512 = 2^9

### Final Address Fields (20-bit Address)

| Field | Bits |
|--------|------|
| Tag | 6 bits |
| Index | 9 bits |
| Block Offset | 5 bits |

---

## Replacement Policy: Pseudo-LRU

This design uses a tree-based Pseudo-LRU algorithm.

- Uses 3 bits per set for 4-way associativity.
- Provides an approximation of true LRU.
- Lower hardware complexity than full LRU implementation.
- Hardware-efficient and commonly used in real processor caches.
