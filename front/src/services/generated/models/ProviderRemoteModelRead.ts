/* generated using openapi-typescript-codegen -- do not edit */
/* istanbul ignore file */
/* tslint:disable */
/* eslint-disable */
/**
 * 供应商远端模型清单条目（来自上游 /models 接口）。
 */
export type ProviderRemoteModelRead = {
    /**
     * 上游模型名称（如 gpt-4o / viduq2）
     */
    id: string;
    /**
     * 上游归属方（OpenAI 兼容字段，可能缺失）
     */
    owned_by?: (string | null);
};

