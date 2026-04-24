#include "dwrite_resolver.h"

#ifdef _WIN32

#define COBJMACROS
#include <initguid.h>
#include <dwrite.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

static int utf8_to_utf16(const char *src, wchar_t *dst, int dst_len) {
    if (!src || !dst || dst_len <= 0) return 0;
    const int written = MultiByteToWideChar(CP_UTF8, 0, src, -1, dst, dst_len);
    return written > 0;
}

static int utf16_to_utf8(const wchar_t *src, char *dst, int dst_len) {
    if (!src || !dst || dst_len <= 0) return 0;
    const int written = WideCharToMultiByte(CP_UTF8, 0, src, -1, dst, dst_len, NULL, NULL);
    return written > 0;
}

static int get_localized_string_utf8(IDWriteLocalizedStrings *strings, char *dst, int dst_len) {
    UINT32 index = 0;
    BOOL exists = FALSE;
    wchar_t wide[256];
    UINT32 len = 0;
    HRESULT hr;

    if (!strings || !dst || dst_len <= 0) return 0;

    hr = IDWriteLocalizedStrings_FindLocaleName(strings, L"en-us", &index, &exists);
    if (FAILED(hr) || !exists) index = 0;

    hr = IDWriteLocalizedStrings_GetStringLength(strings, index, &len);
    if (FAILED(hr) || len + 1 > (UINT32)(sizeof(wide) / sizeof(wide[0]))) return 0;
    hr = IDWriteLocalizedStrings_GetString(strings, index, wide, (UINT32)(sizeof(wide) / sizeof(wide[0])));
    if (FAILED(hr)) return 0;
    return utf16_to_utf8(wide, dst, dst_len);
}

int hollow_dwrite_match_font(const char *family_utf8, int want_bold, int want_italic, HollowDWriteFontMatch *out_match) {
    IDWriteFactory *factory = NULL;
    IDWriteFontCollection *collection = NULL;
    HRESULT hr;
    UINT32 family_index = 0;
    BOOL family_exists = FALSE;
    UINT32 family_count = 0;
    UINT32 best_score = 0;
    UINT32 best_font_index = UINT32_MAX;
    wchar_t family_utf16[256];

    if (!family_utf8 || !out_match) return 0;
    memset(out_match, 0, sizeof(*out_match));

    if (!utf8_to_utf16(family_utf8, family_utf16, (int)(sizeof(family_utf16) / sizeof(family_utf16[0])))) return 0;

    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, (IUnknown **)&factory);
    if (FAILED(hr) || !factory) return 0;

    hr = IDWriteFactory_GetSystemFontCollection(factory, &collection, FALSE);
    if (FAILED(hr) || !collection) {
        IDWriteFactory_Release(factory);
        return 0;
    }

    IDWriteFontCollection_FindFamilyName(collection, family_utf16, &family_index, &family_exists);
    if (!family_exists) {
        IDWriteFontCollection_Release(collection);
        IDWriteFactory_Release(factory);
        return 0;
    }

    {
        IDWriteFontFamily *family = NULL;
        hr = IDWriteFontCollection_GetFontFamily(collection, family_index, &family);
        if (FAILED(hr) || !family) {
            IDWriteFontCollection_Release(collection);
            IDWriteFactory_Release(factory);
            return 0;
        }

        family_count = IDWriteFontFamily_GetFontCount(family);
        for (UINT32 i = 0; i < family_count; ++i) {
            IDWriteFont *font = NULL;
            UINT32 score = 0;
            DWRITE_FONT_WEIGHT weight;
            DWRITE_FONT_STYLE style;
            hr = IDWriteFontFamily_GetFont(family, i, &font);
            if (FAILED(hr) || !font) continue;

            weight = IDWriteFont_GetWeight(font);
            style = IDWriteFont_GetStyle(font);

            if (want_bold) {
                score += (weight >= DWRITE_FONT_WEIGHT_SEMI_BOLD) ? 10 : 0;
            } else {
                score += (weight <= DWRITE_FONT_WEIGHT_MEDIUM) ? 10 : 0;
            }
            if (want_italic) {
                score += (style == DWRITE_FONT_STYLE_ITALIC || style == DWRITE_FONT_STYLE_OBLIQUE) ? 10 : 0;
            } else {
                score += (style == DWRITE_FONT_STYLE_NORMAL) ? 10 : 0;
            }

            if (best_font_index == UINT32_MAX || score > best_score) {
                best_score = score;
                best_font_index = i;
            }
            IDWriteFont_Release(font);
        }

        if (best_font_index != UINT32_MAX) {
            IDWriteFont *font = NULL;
            IDWriteFontFace *font_face = NULL;
            IDWriteFontFile *font_file = NULL;
            IDWriteFontFileLoader *loader = NULL;
            IDWriteLocalFontFileLoader *local_loader = NULL;
            const void *reference_key = NULL;
            UINT32 reference_key_size = 0;
            UINT32 file_count = 0;
            UINT32 face_index_out = 0;
            wchar_t path_utf16[1024];

            hr = IDWriteFontFamily_GetFont(family, best_font_index, &font);
            if (SUCCEEDED(hr) && font) hr = IDWriteFont_CreateFontFace(font, &font_face);
            if (SUCCEEDED(hr) && font_face) file_count = IDWriteFontFace_GetFiles(font_face, &file_count, NULL);
            if (SUCCEEDED(hr) && font_face && file_count > 0) {
                IDWriteFontFile *files[1] = {0};
                UINT32 requested = 1;
                hr = IDWriteFontFace_GetFiles(font_face, &requested, files);
                if (SUCCEEDED(hr) && files[0]) font_file = files[0];
            }
            if (SUCCEEDED(hr) && font_file) hr = IDWriteFontFile_GetLoader(font_file, &loader);
            if (SUCCEEDED(hr) && loader) hr = IDWriteFontFileLoader_QueryInterface(loader, &IID_IDWriteLocalFontFileLoader, (void **)&local_loader);
            if (SUCCEEDED(hr) && local_loader) {
                IDWriteFontFile_GetReferenceKey(font_file, &reference_key, &reference_key_size);
                hr = IDWriteLocalFontFileLoader_GetFilePathFromKey(local_loader, reference_key, reference_key_size, path_utf16, (UINT32)(sizeof(path_utf16) / sizeof(path_utf16[0])));
            }
            if (SUCCEEDED(hr) && font_face) face_index_out = IDWriteFontFace_GetIndex(font_face);
            if (SUCCEEDED(hr) && utf16_to_utf8(path_utf16, out_match->path, (int)sizeof(out_match->path))) {
                out_match->face_index = face_index_out;
                if (local_loader) IDWriteLocalFontFileLoader_Release(local_loader);
                if (loader) IDWriteFontFileLoader_Release(loader);
                if (font_file) IDWriteFontFile_Release(font_file);
                if (font_face) IDWriteFontFace_Release(font_face);
                if (font) IDWriteFont_Release(font);
                IDWriteFontFamily_Release(family);
                IDWriteFontCollection_Release(collection);
                IDWriteFactory_Release(factory);
                return 1;
            }

            if (local_loader) IDWriteLocalFontFileLoader_Release(local_loader);
            if (loader) IDWriteFontFileLoader_Release(loader);
            if (font_file) IDWriteFontFile_Release(font_file);
            if (font_face) IDWriteFontFace_Release(font_face);
            if (font) IDWriteFont_Release(font);
        }

        IDWriteFontFamily_Release(family);
    }

    IDWriteFontCollection_Release(collection);
    IDWriteFactory_Release(factory);
    return 0;
}

int hollow_dwrite_list_font_families(HollowDWriteFontFamilyCallback callback, void *ctx) {
    IDWriteFactory *factory = NULL;
    IDWriteFontCollection *collection = NULL;
    HRESULT hr;

    if (!callback) return 0;

    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, (IUnknown **)&factory);
    if (FAILED(hr) || !factory) return 0;

    hr = IDWriteFactory_GetSystemFontCollection(factory, &collection, FALSE);
    if (FAILED(hr) || !collection) {
        IDWriteFactory_Release(factory);
        return 0;
    }

    {
        const UINT32 family_count = IDWriteFontCollection_GetFontFamilyCount(collection);
        for (UINT32 i = 0; i < family_count; ++i) {
            IDWriteFontFamily *family = NULL;
            IDWriteLocalizedStrings *names = NULL;
            UINT32 index = 0;
            BOOL exists = FALSE;
            wchar_t wide_name[256];
            char utf8_name[512];

            hr = IDWriteFontCollection_GetFontFamily(collection, i, &family);
            if (FAILED(hr) || !family) continue;
            hr = IDWriteFontFamily_GetFamilyNames(family, &names);
            if (FAILED(hr) || !names) {
                IDWriteFontFamily_Release(family);
                continue;
            }

            hr = IDWriteLocalizedStrings_FindLocaleName(names, L"en-us", &index, &exists);
            if (FAILED(hr) || !exists) index = 0;

            {
                UINT32 name_len = 0;
                hr = IDWriteLocalizedStrings_GetStringLength(names, index, &name_len);
                if (SUCCEEDED(hr) && name_len + 1 <= (UINT32)(sizeof(wide_name) / sizeof(wide_name[0]))) {
                    hr = IDWriteLocalizedStrings_GetString(names, index, wide_name, (UINT32)(sizeof(wide_name) / sizeof(wide_name[0])));
                    if (SUCCEEDED(hr) && utf16_to_utf8(wide_name, utf8_name, (int)sizeof(utf8_name))) {
                        if (!callback(utf8_name, ctx)) {
                            IDWriteLocalizedStrings_Release(names);
                            IDWriteFontFamily_Release(family);
                            IDWriteFontCollection_Release(collection);
                            IDWriteFactory_Release(factory);
                            return 1;
                        }
                    }
                }
            }

            IDWriteLocalizedStrings_Release(names);
            IDWriteFontFamily_Release(family);
        }
    }

    IDWriteFontCollection_Release(collection);
    IDWriteFactory_Release(factory);
    return 1;
}

int hollow_dwrite_list_font_faces(HollowDWriteFontFaceCallback callback, void *ctx) {
    IDWriteFactory *factory = NULL;
    IDWriteFontCollection *collection = NULL;
    HRESULT hr;

    if (!callback) return 0;

    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, (IUnknown **)&factory);
    if (FAILED(hr) || !factory) return 0;

    hr = IDWriteFactory_GetSystemFontCollection(factory, &collection, FALSE);
    if (FAILED(hr) || !collection) {
        IDWriteFactory_Release(factory);
        return 0;
    }

    {
        const UINT32 family_count = IDWriteFontCollection_GetFontFamilyCount(collection);
        for (UINT32 i = 0; i < family_count; ++i) {
            IDWriteFontFamily *family = NULL;
            IDWriteLocalizedStrings *family_names = NULL;
            char family_utf8[512];

            hr = IDWriteFontCollection_GetFontFamily(collection, i, &family);
            if (FAILED(hr) || !family) continue;
            hr = IDWriteFontFamily_GetFamilyNames(family, &family_names);
            if (FAILED(hr) || !family_names) {
                IDWriteFontFamily_Release(family);
                continue;
            }
            if (!get_localized_string_utf8(family_names, family_utf8, (int)sizeof(family_utf8))) {
                IDWriteLocalizedStrings_Release(family_names);
                IDWriteFontFamily_Release(family);
                continue;
            }

            {
                const UINT32 font_count = IDWriteFontFamily_GetFontCount(family);
                for (UINT32 font_index = 0; font_index < font_count; ++font_index) {
                    IDWriteFont *font = NULL;
                    IDWriteLocalizedStrings *face_names = NULL;
                    char style_utf8[512];

                    hr = IDWriteFontFamily_GetFont(family, font_index, &font);
                    if (FAILED(hr) || !font) continue;
                    hr = IDWriteFont_GetFaceNames(font, &face_names);
                    if (FAILED(hr) || !face_names) {
                        IDWriteFont_Release(font);
                        continue;
                    }
                    if (get_localized_string_utf8(face_names, style_utf8, (int)sizeof(style_utf8))) {
                        if (!callback(family_utf8, style_utf8, ctx)) {
                            IDWriteLocalizedStrings_Release(face_names);
                            IDWriteFont_Release(font);
                            IDWriteLocalizedStrings_Release(family_names);
                            IDWriteFontFamily_Release(family);
                            IDWriteFontCollection_Release(collection);
                            IDWriteFactory_Release(factory);
                            return 1;
                        }
                    }
                    IDWriteLocalizedStrings_Release(face_names);
                    IDWriteFont_Release(font);
                }
            }

            IDWriteLocalizedStrings_Release(family_names);
            IDWriteFontFamily_Release(family);
        }
    }

    IDWriteFontCollection_Release(collection);
    IDWriteFactory_Release(factory);
    return 1;
}

#else

int hollow_dwrite_match_font(const char *family_utf8, int want_bold, int want_italic, HollowDWriteFontMatch *out_match) {
    (void)family_utf8;
    (void)want_bold;
    (void)want_italic;
    (void)out_match;
    return 0;
}

int hollow_dwrite_list_font_families(HollowDWriteFontFamilyCallback callback, void *ctx) {
    (void)callback;
    (void)ctx;
    return 0;
}

int hollow_dwrite_list_font_faces(HollowDWriteFontFaceCallback callback, void *ctx) {
    (void)callback;
    (void)ctx;
    return 0;
}

#endif
