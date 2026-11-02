#include "NativeFunctions.h"

// Private Swift names are stripped; match code while ignoring PC-relative relocations.
typedef struct {
    UUNativeFunction function;
    size_t count;
    uint32_t words[32];
} UUSignature;

static const UUSignature signatures[] = {
    { UUZoom, 24, {
        0x6dbe23e9u, 0xa9017bfdu, 0x910043fdu, 0xd0010b88u,
        0xf941b908u, 0xfc686a88u, 0x1e602100u, 0x540000ccu,
        0xd0010b88u, 0xf941bd08u, 0xfc686a81u, 0x1e602020u,
        0x1e604c28u, 0xd0010b88u, 0xf941b108u, 0xd2e7fe09u,
        0xf8286a89u, 0xd0010b88u, 0xf941c508u, 0x8b080288u,
        0xa9007d1fu, 0x52800029u, 0x39004109u, 0xd0010b88u,
    } },
    { UUZoom, 24, {
        0x6dbd23e9u, 0xa9014ff4u, 0xa9027bfdu, 0x910083fdu,
        0x1e604008u, 0xf0010808u, 0xf944c913u, 0xf8736a80u,
        0xb0010168u, 0xf9400d01u, 0x945f6619u, 0xf8736a80u,
        0xf8336a9fu, 0x945f662eu, 0xf0010808u, 0xf944cd08u,
        0x8b080288u, 0xa9007d1fu, 0xf0010808u, 0xf944d908u,
        0x38286a9fu, 0xf0010808u, 0xf9449108u, 0xd2e7fe09u,
    } },
    { UUOffset, 32, {
        0x6db923e9u, 0xa9016ffcu, 0xa90267fau, 0xa9035ff8u,
        0xa90457f6u, 0xa9054ff4u, 0xa9067bfdu, 0x910183fdu,
        0xd10043ffu, 0x1e604028u, 0x1e604009u, 0xd2800000u,
        0x940bb00cu, 0xaa0003f3u, 0xf85f801au, 0xf9402348u,
        0xaa0803e9u, 0xd000f450u, 0xf943f610u, 0xd63f0200u,
        0x910003e9u, 0x91003d08u, 0x927ced08u, 0xcb080135u,
        0x910002bfu, 0x90010b88u, 0xf941cd08u, 0x38686a88u,
        0x7100051fu, 0x54000ec1u, 0x1e604120u, 0x1e604101u,
    } },
    { UUOffset, 32, {
        0x6db923e9u, 0xa9016ffcu, 0xa90267fau, 0xa9035ff8u,
        0xa90457f6u, 0xa9054ff4u, 0xa9067bfdu, 0x910183fdu,
        0xd10043ffu, 0x1e604028u, 0x1e604009u, 0xd2800000u,
        0x940bb14cu, 0xaa0003f3u, 0xf85f801au, 0xf9402348u,
        0xaa0803e9u, 0xb000f0f0u, 0xf943f210u, 0xd63f0200u,
        0x910003e9u, 0x91003d08u, 0x927ced08u, 0xcb080135u,
        0x910002bfu, 0x90010828u, 0xf944e908u, 0x38686a88u,
        0x7100051fu, 0x54001101u, 0x90010828u, 0xf944c916u,
    } },
    { UUWheelBuild, 24, {
        0xa9bc5ff8u, 0xa90157f6u, 0xa9024ff4u, 0xa9037bfdu,
        0x9100c3fdu, 0xd100c3ffu, 0xaa0303f5u, 0xaa0203f6u,
        0xaa0103f7u, 0xaa0003f8u, 0xd2800000u, 0x9477a9ddu,
        0xf85f8008u, 0xf9402108u, 0xaa0803e9u, 0xf0012350u,
        0xf943f610u, 0xd63f0200u, 0x910003e9u, 0x91003d08u,
        0x927ced08u, 0xcb080133u, 0x9100027fu, 0xd2800000u,
    } },
    { UUWheelTransport, 24, {
        0xd10203ffu, 0xa9026ffcu, 0xa90367fau, 0xa9045ff8u,
        0xa90557f6u, 0xa9064ff4u, 0xa9077bfdu, 0x9101c3fdu,
        0xaa0303f3u, 0xaa0203f4u, 0xaa0103f5u, 0x91004020u,
        0x910023e1u, 0xd2800002u, 0xd2800003u, 0x94624ed9u,
        0xf9400ab7u, 0xb7f80737u, 0xb40005f7u, 0xd0010dc8u,
        0xf9422508u, 0xb100051fu, 0x540006a1u, 0xd0011d28u,
    } },
};

static uint32_t UUInstructionMask(uint32_t word, uint32_t previous) {
    if ((word & 0x9f000000u) == 0x90000000u) return 0x9f00001fu; // ADRP
    if ((word & 0xfc000000u) == 0x94000000u) return 0xfc000000u; // BL
    if ((previous & 0x9f000000u) == 0x90000000u &&
        ((word >> 5) & 31) == (previous & 31) &&
        ((word & 0xffc00000u) == 0xf9400000u || (word & 0xffc00000u) == 0x91000000u)) {
        return 0xffc003ffu; // ADRP + LDR/ADD address pair
    }
    return UINT32_MAX;
}

const void *UUResolveNativeFunction(const uint32_t *text, size_t byteCount, UUNativeFunction function) {
    if (!text || function < 0 || function >= UUNativeFunctionCount) return NULL;
    const void *found = NULL;
    size_t wordCount = byteCount / sizeof(uint32_t);
    for (size_t s = 0; s < sizeof(signatures) / sizeof(signatures[0]); s++) {
        const UUSignature *signature = &signatures[s];
        if (signature->function != function || signature->count > wordCount) continue;
        uint32_t masks[32];
        for (size_t j = 0; j < signature->count; j++) {
            masks[j] = UUInstructionMask(signature->words[j], j ? signature->words[j - 1] : 0);
        }
        for (size_t i = 0; i <= wordCount - signature->count; i++) {
            if (text[i] != signature->words[0]) continue;
            size_t j = 1;
            for (; j < signature->count; j++) {
                if ((text[i + j] & masks[j]) != (signature->words[j] & masks[j])) break;
            }
            if (j == signature->count) {
                if (found && found != &text[i]) return NULL;
                found = &text[i];
            }
        }
    }
    return found;
}
