/* generated using openapi-typescript-codegen -- do not edit */
/* istanbul ignore file */
/* tslint:disable */
/* eslint-disable */
import type { ProviderRemoteModelRead } from './ProviderRemoteModelRead';
/**
 * 供应商远端模型清单（代理上游 OpenAI 兼容 GET /v1/models）。
 */
export type ProviderRemoteModelsRead = {
    /**
     * 供应商 ID
     */
    provider_id: string;
    /**
     * 模型列表
     */
    items?: Array<ProviderRemoteModelRead>;
};

