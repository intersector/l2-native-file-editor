/// Which part of a field a value belongs to. Together with the field index and an element index
/// it addresses exactly one txt column through `ColumnPlan.column(field:part:index:)`.
enum LeafPart {
    /// Scalar, table element or FILLER.
    case element
    /// MTX*: `_cntm`.
    case meshCount
    /// MTX: `_m[i]`; MTX2: `_m[i]`; MTX3: `_mU[i]`.
    case mesh
    /// MTX2: `_m[i]_id` (UINT).
    case meshID
    /// MTX2: `_m[i]_cnt` (UCHAR).
    case meshCnt
    /// MTX3: `_mB[i][1]` (UCHAR).
    case meshByte1
    /// MTX3: `_mB[i][2]` (UCHAR).
    case meshByte2
    /// MTX*: `_cntt`.
    case textureCount
    /// MTX*: `_t[i]`.
    case texture
    /// MTX3: `_tE`.
    case textureExtra
    /// MAT*: `_cnt`.
    case materialCount
    /// MAT2: `_extra`.
    case materialExtra
    /// MAT*: `_m[i]_id`.
    case materialID
    /// MAT*: `_m[i]_cnt`.
    case materialValue
}
