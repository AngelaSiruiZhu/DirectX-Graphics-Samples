//*********************************************************
// Interval Shading Tetrahedron - Main Application
// Demonstrates depth visualization using Interval Shading
//*********************************************************

#pragma once

#include "DXSample.h"
#include <vector>
#include <map>
#include <string>

using namespace DirectX;
using Microsoft::WRL::ComPtr;

struct SceneObject
{
    std::string MeshName;
    XMFLOAT4X4 WorldMatrix;
    // Cached indices into the global mesh buffers
    UINT IndexCount;
    UINT VertexCount;
    // We need offsets if we pack multiple meshes into one buffer, 
    // OR we can keep a separate buffer per mesh type.
    // For simplicity given the current architecture, let's assume we load ONE unique mesh type per object 
    // or we store the resource pointer here.
    // Better: Store an index into a m_meshes vector.
    size_t MeshIndex; 
};

struct MeshData
{
    std::vector<XMFLOAT4> Vertices;
    std::vector<uint32_t> Indices;
    ComPtr<ID3D12Resource> VertexBuffer;
    ComPtr<ID3D12Resource> IndexBuffer; // TetBuffer
    std::string Name;
};

class IntervalShadingTetrahedron : public DXSample
{
public:
    IntervalShadingTetrahedron(UINT width, UINT height, std::wstring name);

    virtual void OnInit();
    virtual void OnUpdate();
    virtual void OnRender();
    virtual void OnDestroy();
    virtual void OnKeyDown(UINT8 key);

private:
    static const UINT FrameCount = 2;

    _declspec(align(256u)) struct SceneConstantBuffer
    {
        XMFLOAT4X4 Model;
        XMFLOAT4X4 View;
        XMFLOAT4X4 Proj;
        XMFLOAT4X4 ViewProj;
        XMFLOAT4X4 InvViewProj;
        float NearPlane;
        float Density;
        uint32_t DebugMode;
        uint32_t TetCount;
        uint32_t RandomizeOrder;
        XMFLOAT3 CameraPos;
        float Time;
        XMFLOAT3 LightDir;
        uint32_t TetOffset; // Offset into global index buffer
    };

    // Pipeline objects
    CD3DX12_VIEWPORT m_viewport;
    CD3DX12_RECT m_scissorRect;
    ComPtr<IDXGISwapChain3> m_swapChain;
    ComPtr<ID3D12Device2> m_device;
    ComPtr<ID3D12Resource> m_renderTargets[FrameCount];
    ComPtr<ID3D12Resource> m_depthStencil;
    ComPtr<ID3D12CommandAllocator> m_commandAllocators[FrameCount];
    ComPtr<ID3D12CommandQueue> m_commandQueue;
    ComPtr<ID3D12RootSignature> m_intervalRootSignature;
    ComPtr<ID3D12RootSignature> m_compositeRootSignature;
    ComPtr<ID3D12DescriptorHeap> m_rtvHeap;
    ComPtr<ID3D12DescriptorHeap> m_srvHeap;
    ComPtr<ID3D12DescriptorHeap> m_dsvHeap;
    ComPtr<ID3D12PipelineState> m_intervalPipelineState;
    ComPtr<ID3D12PipelineState> m_compositePipelineState;
    ComPtr<ID3D12PipelineState> m_debugPipelineState;
    ComPtr<ID3D12Resource> m_frontRT;
    ComPtr<ID3D12Resource> m_backRT;
    ComPtr<ID3D12Resource> m_opticalDepthRT;
    D3D12_RESOURCE_STATES m_frontState;
    D3D12_RESOURCE_STATES m_backState;
    D3D12_RESOURCE_STATES m_opticalState;
    ComPtr<ID3D12Resource> m_constantBuffer;
    UINT m_srvDescriptorSize;
    UINT m_rtvDescriptorSize;
    UINT64 m_cbStride = 0;

    ComPtr<ID3D12GraphicsCommandList6> m_commandList;
    SceneConstantBuffer m_constantBufferData;
    UINT8* m_cbvDataBegin;

    // Free-fly camera
    float m_cameraPosX;
    float m_cameraPosY;
    float m_cameraPosZ;
    float m_cameraYaw;    // Left/right rotation
    float m_cameraPitch;  // Up/down rotation
    XMFLOAT3 m_viewForward;  // Actual view forward direction
    XMFLOAT3 m_viewRight;    // Actual view right direction
    bool m_randomizeDrawOrder;

    // Synchronization objects
    UINT m_frameIndex;
    HANDLE m_fenceEvent;
    ComPtr<ID3D12Fence> m_fence;
    UINT64 m_fenceValues[FrameCount];

    // Mesh data
    std::vector<XMFLOAT4> m_vertices; 
    std::vector<uint32_t> m_tetIndices; 
    ComPtr<ID3D12Resource> m_vertexBuffer; 
    ComPtr<ID3D12Resource> m_tetBuffer; 
    
    // New Scene Data
    std::vector<MeshData> m_meshes;
    std::vector<SceneObject> m_sceneObjects;
    
    uint8_t* m_tetBufferMapped = nullptr; // TODO: Handle shuffling for multiple meshes or remove
    XMFLOAT4X4 m_modelMatrix; // Keep for fallback or debug

    bool LoadTetrahedralMesh(const std::wstring& path, MeshData& outMesh);
    void LoadScene(const std::wstring& scenePath);
    void OpenMeshFile();
    void CreateIntervalTargets();
    void CreateSrvHeap();
    void BuildIntervalPipelineState();
    void BuildCompositePipelineState();
    void BuildDebugPipelineState();
    void UploadBuffer(ID3D12Resource** destination, const void* data, size_t byteSize);
    void ShuffleTets();
    void UpdateConstants();
    void LoadPipeline();
    void LoadAssets();
    void PopulateCommandList();
    void MoveToNextFrame();
    void WaitForGpu();
    std::vector<BYTE> ReadData(const std::wstring& filename);
};

