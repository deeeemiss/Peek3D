#import "Peek3DDracoDecompressor.h"

#import <GLTFKit2/GLTFKit2.h>

#include <limits>
#include <memory>
#include <string>

#include "draco/compression/decode.h"

// Derived from the Draco sample plugin that ships with GLTFKit2
// (GLTFViewer/macOS/SampleDracoPlugin.mm), hardened for files nobody vetted:
// the compressed stream, the attribute map and every size derived from them
// come from the file, so each one is checked before it is used, and every
// failure ends in `nil` plus a recorded reason instead of a crash.

namespace {

/// First failure on this thread since the last clear. GLTFKit2 decodes on the
/// thread that called it, and Peek3D loads each file on a thread of its own,
/// so concurrent loads (several windows) don't see each other's failures.
thread_local std::string gFailure;

/// Far above any real mesh, low enough that the size arithmetic below cannot
/// overflow and a forged count cannot ask for gigabytes.
constexpr size_t kMaxPoints = size_t(1) << 26;
constexpr size_t kMaxFaces = size_t(1) << 26;

void Fail(const std::string &reason) {
    if (gFailure.empty()) {
        gFailure = reason;
    }
}

bool ComponentTypeForDracoType(draco::DataType type, GLTFComponentType *out) {
    switch (type) {
        case draco::DT_INT8:    *out = GLTFComponentTypeByte; return true;
        case draco::DT_UINT8:   *out = GLTFComponentTypeUnsignedByte; return true;
        case draco::DT_INT16:   *out = GLTFComponentTypeShort; return true;
        case draco::DT_UINT16:  *out = GLTFComponentTypeUnsignedShort; return true;
        case draco::DT_UINT32:  *out = GLTFComponentTypeUnsignedInt; return true;
        case draco::DT_FLOAT32: *out = GLTFComponentTypeFloat; return true;
        default: return false; // glTF has no 64-bit, bool or signed 32-bit components
    }
}

bool DimensionForComponentCount(int count, GLTFValueDimension *out) {
    switch (count) {
        case 1: *out = GLTFValueDimensionScalar; return true;
        case 2: *out = GLTFValueDimensionVector2; return true;
        case 3: *out = GLTFValueDimensionVector3; return true;
        case 4: *out = GLTFValueDimensionVector4; return true;
        default: return false;
    }
}

/// One attribute's values, one element per point, tightly packed. nil on any
/// inconsistency in the decoded attribute.
NSData *CopyAttribute(const draco::PointAttribute &attribute, size_t pointCount, NSString *name) {
    const size_t componentCount = attribute.num_components();
    const size_t componentSize = draco::DataTypeLength(attribute.data_type());
    const size_t elementSize = componentCount * componentSize;
    if (componentCount < 1 || componentCount > 4 || componentSize < 1 || elementSize > 16) {
        Fail("attribute " + std::string(name.UTF8String) + " has an unsupported shape");
        return nil;
    }
    if (attribute.byte_stride() != elementSize) {
        Fail("attribute " + std::string(name.UTF8String) + " is not tightly packed");
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:pointCount * elementSize];
    if (data == nil) {
        Fail("out of memory");
        return nil;
    }
    uint8_t *out = static_cast<uint8_t *>(data.mutableBytes);
    const size_t valueCount = attribute.size();

    if (attribute.is_mapping_identity()) {
        if (valueCount < pointCount) {
            Fail("attribute " + std::string(name.UTF8String) + " has fewer values than points");
            return nil;
        }
        std::memcpy(out, attribute.GetAddress(draco::AttributeValueIndex(0)), pointCount * elementSize);
        return data;
    }
    for (size_t i = 0; i < pointCount; ++i) {
        const draco::AttributeValueIndex valueIndex = attribute.mapped_index(draco::PointIndex(static_cast<uint32_t>(i)));
        if (valueIndex.value() >= valueCount) {
            Fail("attribute " + std::string(name.UTF8String) + " maps a point outside its values");
            return nil;
        }
        attribute.GetValue(valueIndex, out + i * elementSize);
    }
    return data;
}

GLTFAccessor *AccessorForData(NSData *data, GLTFComponentType type, GLTFValueDimension dimension,
                              size_t count, BOOL normalized) {
    GLTFBuffer *buffer = [[GLTFBuffer alloc] initWithData:data];
    GLTFBufferView *view = [[GLTFBufferView alloc] initWithBuffer:buffer
                                                           length:(NSInteger)data.length
                                                           offset:0
                                                           stride:0];
    return [[GLTFAccessor alloc] initWithBufferView:view
                                             offset:0
                                      componentType:type
                                          dimension:dimension
                                              count:(NSInteger)count
                                         normalized:normalized];
}

} // namespace

@implementation Peek3DDracoDecompressor

+ (void)registerWithGLTFKit {
    GLTFAsset.dracoDecompressorClassName = NSStringFromClass(self);
}

+ (void)clearFailure {
    gFailure.clear();
}

+ (NSString *)takeFailureReason {
    if (gFailure.empty()) {
        return nil;
    }
    NSString *reason = [NSString stringWithUTF8String:gFailure.c_str()];
    gFailure.clear();
    return reason ?: @"Draco decoding failed";
}

+ (GLTFPrimitive *)newPrimitiveForCompressedBufferView:(GLTFBufferView *)bufferView
                                          attributeMap:(NSDictionary<NSString *, NSNumber *> *)attributeMap {
    @autoreleasepool {
        // After one failure the whole load is lost; don't spend time decoding the rest.
        if (!gFailure.empty()) {
            return nil;
        }

        // The compressed bytes must lie inside the buffer that backs the view.
        NSData *backing = bufferView.buffer.data;
        const NSInteger offset = bufferView.offset;
        const NSInteger length = bufferView.length;
        if (backing == nil || offset < 0 || length < 1 ||
            (NSUInteger)offset > backing.length || (NSUInteger)length > backing.length - (NSUInteger)offset) {
            Fail("compressed buffer view lies outside its buffer");
            return nil;
        }
        if (attributeMap.count == 0) {
            Fail("no attributes listed for the compressed primitive");
            return nil;
        }

        draco::DecoderBuffer buffer;
        buffer.Init(static_cast<const char *>(backing.bytes) + offset, (size_t)length);

        const auto typeOrStatus = draco::Decoder::GetEncodedGeometryType(&buffer);
        if (!typeOrStatus.ok()) {
            Fail("not a Draco stream");
            return nil;
        }
        if (typeOrStatus.value() != draco::TRIANGULAR_MESH) {
            // glTF primitives that use Draco are triangle meshes; a point
            // cloud here would be a mislabeled file.
            Fail("Draco stream is not a triangle mesh");
            return nil;
        }

        draco::Decoder decoder;
        auto meshOrStatus = decoder.DecodeMeshFromBuffer(&buffer);
        if (!meshOrStatus.ok()) {
            Fail("Draco stream is damaged or truncated");
            return nil;
        }
        const std::unique_ptr<draco::Mesh> mesh = std::move(meshOrStatus).value();
        if (mesh == nullptr) {
            Fail("Draco stream decoded to nothing");
            return nil;
        }

        const size_t pointCount = mesh->num_points();
        const size_t faceCount = mesh->num_faces();
        if (pointCount < 1 || pointCount > kMaxPoints || faceCount < 1 || faceCount > kMaxFaces) {
            Fail("Draco mesh has an implausible size");
            return nil;
        }

        NSMutableArray<GLTFAttribute *> *attributes = [NSMutableArray arrayWithCapacity:attributeMap.count];
        for (NSString *name in attributeMap) {
            NSNumber *uniqueId = attributeMap[name];
            if (![name isKindOfClass:NSString.class] || ![uniqueId isKindOfClass:NSNumber.class] ||
                uniqueId.longLongValue < 0 || uniqueId.longLongValue > std::numeric_limits<uint32_t>::max()) {
                Fail("malformed attribute map");
                return nil;
            }
            const draco::PointAttribute *attribute = mesh->GetAttributeByUniqueId(uniqueId.unsignedIntValue);
            if (attribute == nullptr) {
                Fail("attribute " + std::string(name.UTF8String) + " is not in the Draco stream");
                return nil;
            }
            GLTFComponentType componentType;
            GLTFValueDimension dimension;
            if (!ComponentTypeForDracoType(attribute->data_type(), &componentType) ||
                !DimensionForComponentCount(attribute->num_components(), &dimension)) {
                Fail("attribute " + std::string(name.UTF8String) + " has a type glTF can't express");
                return nil;
            }
            NSData *values = CopyAttribute(*attribute, pointCount, name);
            if (values == nil) {
                return nil;
            }
            GLTFAccessor *accessor = AccessorForData(values, componentType, dimension, pointCount,
                                                     attribute->normalized());
            [attributes addObject:[[GLTFAttribute alloc] initWithName:name accessor:accessor]];
        }

        // Indices: every corner must name a real point, or SceneKit reads past
        // the vertex arrays when it draws.
        NSMutableData *indexData = [NSMutableData dataWithLength:faceCount * 3 * sizeof(uint32_t)];
        if (indexData == nil) {
            Fail("out of memory");
            return nil;
        }
        uint32_t *indices = static_cast<uint32_t *>(indexData.mutableBytes);
        for (size_t f = 0; f < faceCount; ++f) {
            const auto &face = mesh->face(draco::FaceIndex(static_cast<uint32_t>(f)));
            for (int corner = 0; corner < 3; ++corner) {
                const uint32_t point = face[corner].value();
                if (point >= pointCount) {
                    Fail("Draco face refers to a point that does not exist");
                    return nil;
                }
                indices[f * 3 + corner] = point;
            }
        }
        GLTFAccessor *indexAccessor = AccessorForData(indexData, GLTFComponentTypeUnsignedInt,
                                                      GLTFValueDimensionScalar, faceCount * 3, NO);

        return [[GLTFPrimitive alloc] initWithPrimitiveType:GLTFPrimitiveTypeTriangles
                                                 attributes:attributes
                                                    indices:indexAccessor];
    }
}

@end
