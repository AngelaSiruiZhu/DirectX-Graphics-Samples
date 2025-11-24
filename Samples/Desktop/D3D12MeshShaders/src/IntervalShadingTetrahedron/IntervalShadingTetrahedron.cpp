//*********************************************************
// Interval Shading Tetrahedron - Main Application
// Demonstrates depth visualization using Interval Shading
//*********************************************************

#include "IntervalShadingTetrahedron.h"
#include <fstream>
#include <sstream>
#include <algorithm>
#include <random>
#include <limits>
#include <numeric>
#include <cstring>
#include <stdexcept>
#include <cfloat>
#undef min
#undef max

using DirectX::XMMatrixInverse;

namespace
{
    const wchar_t* kTetPathCandidates[] = {
        L"..\\..\\..\\..\\Assets\\IntervalShading\\bunny.vtk", // from bin/x64/Debug
        L"..\\..\\..\\Assets\\IntervalShading\\bunny.vtk", // from bin/x64/Config
        L"..\\Assets\\IntervalShading\\bunny.vtk",        // from src folder
        L"Samples\\Desktop\\D3D12MeshShaders\\src\\Assets\\IntervalShading\\bunny.vtk" // absolute-ish from repo root
    };
    constexpr float kDefaultDensity = 0.8f;
    constexpr float kNearPlane = 0.1f;
}

IntervalShadingTetrahedron::IntervalShadingTetrahedron(UINT width, UINT height, std::wstring name) :
    DXSample(width, height, name),
    m_frameIndex(0),
    m_viewport(0.0f, 0.0f, static_cast<float>(width), static_cast<float>(height)),
    m_scissorRect(0, 0, static_cast<LONG>(width), static_cast<LONG>(height)),
    m_srvDescriptorSize(0),
    m_rtvDescriptorSize(0),
    m_cbvDataBegin(nullptr),
    m_cameraAngle(0.0f),
    m_cameraElevation(0.35f),
    m_cameraDistance(5.0f),
    m_randomizeDrawOrder(false)
{
    ZeroMemory(m_fenceValues, sizeof(m_fenceValues));
    ZeroMemory(&m_constantBufferData, sizeof(m_constantBufferData));
}

void IntervalShadingTetrahedron::OnInit()
{
    LoadPipeline();
    LoadAssets();
}

void IntervalShadingTetrahedron::LoadPipeline()
{
    UINT dxgiFactoryFlags = 0;

#if defined(_DEBUG)
    {
        ComPtr<ID3D12Debug> debugController;
        if (SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debugController))))
        {
            debugController->EnableDebugLayer();
            dxgiFactoryFlags |= DXGI_CREATE_FACTORY_DEBUG;
        }
    }
#endif

    ComPtr<IDXGIFactory4> factory;
    ThrowIfFailed(CreateDXGIFactory2(dxgiFactoryFlags, IID_PPV_ARGS(&factory)));

    ComPtr<IDXGIAdapter1> hardwareAdapter;
    GetHardwareAdapter(factory.Get(), &hardwareAdapter);

    ThrowIfFailed(D3D12CreateDevice(
        hardwareAdapter.Get(),
        D3D_FEATURE_LEVEL_12_1,
        IID_PPV_ARGS(&m_device)
    ));

    // Check mesh shader support
    D3D12_FEATURE_DATA_D3D12_OPTIONS7 features = {};
    if (FAILED(m_device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS7, &features, sizeof(features))) ||
        features.MeshShaderTier == D3D12_MESH_SHADER_TIER_NOT_SUPPORTED)
    {
        throw std::runtime_error("Mesh shaders are not supported on this device.");
    }

    D3D12_COMMAND_QUEUE_DESC queueDesc = {};
    queueDesc.Flags = D3D12_COMMAND_QUEUE_FLAG_NONE;
    queueDesc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;

    ThrowIfFailed(m_device->CreateCommandQueue(&queueDesc, IID_PPV_ARGS(&m_commandQueue)));

    DXGI_SWAP_CHAIN_DESC1 swapChainDesc = {};
    swapChainDesc.BufferCount = FrameCount;
    swapChainDesc.Width = m_width;
    swapChainDesc.Height = m_height;
    swapChainDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swapChainDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swapChainDesc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    swapChainDesc.SampleDesc.Count = 1;

    ComPtr<IDXGISwapChain1> swapChain;
    ThrowIfFailed(factory->CreateSwapChainForHwnd(
        m_commandQueue.Get(),
        Win32Application::GetHwnd(),
        &swapChainDesc,
        nullptr,
        nullptr,
        &swapChain
    ));

    ThrowIfFailed(factory->MakeWindowAssociation(Win32Application::GetHwnd(), DXGI_MWA_NO_ALT_ENTER));
    ThrowIfFailed(swapChain.As(&m_swapChain));
    m_frameIndex = m_swapChain->GetCurrentBackBufferIndex();

    // Create descriptor heaps
    {
        D3D12_DESCRIPTOR_HEAP_DESC rtvHeapDesc = {};
        rtvHeapDesc.NumDescriptors = FrameCount + 3; // back buffers + front/back/optical
        rtvHeapDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        rtvHeapDesc.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
        ThrowIfFailed(m_device->CreateDescriptorHeap(&rtvHeapDesc, IID_PPV_ARGS(&m_rtvHeap)));

        m_rtvDescriptorSize = m_device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);

        D3D12_DESCRIPTOR_HEAP_DESC dsvHeapDesc = {};
        dsvHeapDesc.NumDescriptors = 1;
        dsvHeapDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_DSV;
        dsvHeapDesc.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
        ThrowIfFailed(m_device->CreateDescriptorHeap(&dsvHeapDesc, IID_PPV_ARGS(&m_dsvHeap)));

        D3D12_DESCRIPTOR_HEAP_DESC srvHeapDesc = {};
        srvHeapDesc.NumDescriptors = 5;
        srvHeapDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        srvHeapDesc.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        ThrowIfFailed(m_device->CreateDescriptorHeap(&srvHeapDesc, IID_PPV_ARGS(&m_srvHeap)));
        m_srvDescriptorSize = m_device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    }

    // Create frame resources
    {
        CD3DX12_CPU_DESCRIPTOR_HANDLE rtvHandle(m_rtvHeap->GetCPUDescriptorHandleForHeapStart());

        for (UINT n = 0; n < FrameCount; n++)
        {
            ThrowIfFailed(m_swapChain->GetBuffer(n, IID_PPV_ARGS(&m_renderTargets[n])));
            m_device->CreateRenderTargetView(m_renderTargets[n].Get(), nullptr, rtvHandle);
            rtvHandle.Offset(1, m_rtvDescriptorSize);

            ThrowIfFailed(m_device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&m_commandAllocators[n])));
        }
    }

    // Create depth stencil
    {
        D3D12_DEPTH_STENCIL_VIEW_DESC depthStencilDesc = {};
        depthStencilDesc.Format = DXGI_FORMAT_D32_FLOAT;
        depthStencilDesc.ViewDimension = D3D12_DSV_DIMENSION_TEXTURE2D;
        depthStencilDesc.Flags = D3D12_DSV_FLAG_NONE;

        D3D12_CLEAR_VALUE depthOptimizedClearValue = {};
        depthOptimizedClearValue.Format = DXGI_FORMAT_D32_FLOAT;
        depthOptimizedClearValue.DepthStencil.Depth = 1.0f;
        depthOptimizedClearValue.DepthStencil.Stencil = 0;

        CD3DX12_HEAP_PROPERTIES heapProps(D3D12_HEAP_TYPE_DEFAULT);
        CD3DX12_RESOURCE_DESC depthDesc = CD3DX12_RESOURCE_DESC::Tex2D(
            DXGI_FORMAT_D32_FLOAT,
            m_width,
            m_height,
            1, 0, 1, 0,
            D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL);

        ThrowIfFailed(m_device->CreateCommittedResource(
            &heapProps,
            D3D12_HEAP_FLAG_NONE,
            &depthDesc,
            D3D12_RESOURCE_STATE_DEPTH_WRITE,
            &depthOptimizedClearValue,
            IID_PPV_ARGS(&m_depthStencil)
        ));

        m_device->CreateDepthStencilView(m_depthStencil.Get(), &depthStencilDesc, m_dsvHeap->GetCPUDescriptorHandleForHeapStart());
    }
}

void IntervalShadingTetrahedron::LoadAssets()
{
    bool loaded = false;
    for (auto path : kTetPathCandidates)
    {
        if (LoadTetrahedralMesh(path))
        {
            loaded = true;
            break;
        }
    }
    if (!loaded)
    {
        throw std::runtime_error("Unable to open tet mesh (checked bunny.vtk in expected locations).");
    }
    CreateIntervalTargets();
    CreateSrvHeap();
    BuildIntervalPipelineState();
    BuildCompositePipelineState();

    // Create the command list (start closed).
    ThrowIfFailed(m_device->CreateCommandList(
        0,
        D3D12_COMMAND_LIST_TYPE_DIRECT,
        m_commandAllocators[m_frameIndex].Get(),
        m_intervalPipelineState.Get(),
        IID_PPV_ARGS(&m_commandList)));
    ThrowIfFailed(m_commandList->Close());

    // Constant buffer
    {
        m_cbStride = (sizeof(SceneConstantBuffer) + 255ull) & ~255ull;
        const UINT64 constantBufferSize = m_cbStride * FrameCount;
        CD3DX12_HEAP_PROPERTIES uploadHeap(D3D12_HEAP_TYPE_UPLOAD);
        CD3DX12_RESOURCE_DESC bufferDesc = CD3DX12_RESOURCE_DESC::Buffer(constantBufferSize);
        ThrowIfFailed(m_device->CreateCommittedResource(
            &uploadHeap,
            D3D12_HEAP_FLAG_NONE,
            &bufferDesc,
            D3D12_RESOURCE_STATE_GENERIC_READ,
            nullptr,
            IID_PPV_ARGS(&m_constantBuffer)));

        CD3DX12_RANGE readRange(0, 0);
        ThrowIfFailed(m_constantBuffer->Map(0, &readRange, reinterpret_cast<void**>(&m_cbvDataBegin)));
    }

    UpdateConstants();

    // Synchronization objects
    {
        ThrowIfFailed(m_device->CreateFence(m_fenceValues[m_frameIndex], D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&m_fence)));
        m_fenceValues[m_frameIndex]++;

        m_fenceEvent = CreateEvent(nullptr, FALSE, FALSE, nullptr);
        if (m_fenceEvent == nullptr)
        {
            ThrowIfFailed(HRESULT_FROM_WIN32(GetLastError()));
        }

        WaitForGpu();
    }
}

void IntervalShadingTetrahedron::OnUpdate()
{
    UpdateConstants();
}

void IntervalShadingTetrahedron::OnRender()
{
    PopulateCommandList();

    ID3D12CommandList* ppCommandLists[] = { m_commandList.Get() };
    m_commandQueue->ExecuteCommandLists(_countof(ppCommandLists), ppCommandLists);

    ThrowIfFailed(m_swapChain->Present(1, 0));

    MoveToNextFrame();
}

void IntervalShadingTetrahedron::PopulateCommandList()
{
    ThrowIfFailed(m_commandAllocators[m_frameIndex]->Reset());
    ThrowIfFailed(m_commandList->Reset(m_commandAllocators[m_frameIndex].Get(), nullptr));

    ID3D12DescriptorHeap* heaps[] = { m_srvHeap.Get() };
    m_commandList->SetDescriptorHeaps(1, heaps);
    m_commandList->RSSetViewports(1, &m_viewport);
    m_commandList->RSSetScissorRects(1, &m_scissorRect);

    D3D12_RESOURCE_STATES shaderRead = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
    auto transitionIf = [&](ComPtr<ID3D12Resource>& res, D3D12_RESOURCE_STATES& state, D3D12_RESOURCE_STATES target)
    {
        if (state != target)
        {
            CD3DX12_RESOURCE_BARRIER b = CD3DX12_RESOURCE_BARRIER::Transition(res.Get(), state, target);
            m_commandList->ResourceBarrier(1, &b);
            state = target;
        }
    };

    // First pass: interval generation into offscreen RTs
    {
        // Bring interval targets to RT state for this frame.
        transitionIf(m_frontRT, m_frontState, D3D12_RESOURCE_STATE_RENDER_TARGET);
        transitionIf(m_backRT, m_backState, D3D12_RESOURCE_STATE_RENDER_TARGET);
        transitionIf(m_opticalDepthRT, m_opticalState, D3D12_RESOURCE_STATE_RENDER_TARGET);

        CD3DX12_CPU_DESCRIPTOR_HANDLE frontHandle(m_rtvHeap->GetCPUDescriptorHandleForHeapStart(), FrameCount, m_rtvDescriptorSize);
        CD3DX12_CPU_DESCRIPTOR_HANDLE backHandle(m_rtvHeap->GetCPUDescriptorHandleForHeapStart(), FrameCount + 1, m_rtvDescriptorSize);
        CD3DX12_CPU_DESCRIPTOR_HANDLE opticalHandle(m_rtvHeap->GetCPUDescriptorHandleForHeapStart(), FrameCount + 2, m_rtvDescriptorSize);

        D3D12_CPU_DESCRIPTOR_HANDLE rtHandles[] = { frontHandle, backHandle, opticalHandle };
        m_commandList->OMSetRenderTargets(_countof(rtHandles), rtHandles, FALSE, nullptr);

        const float clearFront[4] = { FLT_MAX, FLT_MAX, FLT_MAX, FLT_MAX };
        const float clearBack[4]  = { 0, 0, 0, 0 };
        const float clearOptical[4] = { 0, 0, 0, 0 };
        m_commandList->ClearRenderTargetView(frontHandle, clearFront, 0, nullptr);
        m_commandList->ClearRenderTargetView(backHandle, clearBack, 0, nullptr);
        m_commandList->ClearRenderTargetView(opticalHandle, clearOptical, 0, nullptr);

        m_commandList->SetGraphicsRootSignature(m_intervalRootSignature.Get());
        m_commandList->SetPipelineState(m_intervalPipelineState.Get());
        m_commandList->SetGraphicsRootConstantBufferView(0, m_constantBuffer->GetGPUVirtualAddress() + m_cbStride * m_frameIndex);
        m_commandList->SetGraphicsRootDescriptorTable(1, m_srvHeap->GetGPUDescriptorHandleForHeapStart());
        m_commandList->DispatchMesh((m_constantBufferData.TetCount + 15) / 16, 1, 1);

        transitionIf(m_frontRT, m_frontState, shaderRead);
        transitionIf(m_backRT, m_backState, shaderRead);
        transitionIf(m_opticalDepthRT, m_opticalState, shaderRead);
    }

    // Second pass: fullscreen composite to backbuffer
    {
        // Make sure interval outputs are in SRV state for sampling.
        transitionIf(m_frontRT, m_frontState, shaderRead);
        transitionIf(m_backRT,  m_backState,  shaderRead);
        transitionIf(m_opticalDepthRT, m_opticalState, shaderRead);

        CD3DX12_RESOURCE_BARRIER toRT = CD3DX12_RESOURCE_BARRIER::Transition(
            m_renderTargets[m_frameIndex].Get(),
            D3D12_RESOURCE_STATE_PRESENT,
            D3D12_RESOURCE_STATE_RENDER_TARGET);
        m_commandList->ResourceBarrier(1, &toRT);

        CD3DX12_CPU_DESCRIPTOR_HANDLE rtvHandle(m_rtvHeap->GetCPUDescriptorHandleForHeapStart(), m_frameIndex, m_rtvDescriptorSize);
        m_commandList->OMSetRenderTargets(1, &rtvHandle, FALSE, nullptr);

        const float clearColor[] = { 0.0f, 1.0f, 0.0f, 1.0f };
        m_commandList->ClearRenderTargetView(rtvHandle, clearColor, 0, nullptr);

        m_commandList->SetGraphicsRootSignature(m_compositeRootSignature.Get());
        m_commandList->SetPipelineState(m_compositePipelineState.Get());
        m_commandList->SetGraphicsRootConstantBufferView(0, m_constantBuffer->GetGPUVirtualAddress() + m_cbStride * m_frameIndex);
        // Front/back/optical are at SRV heap indices 2/3/4 (t2/t3/t4).
        CD3DX12_GPU_DESCRIPTOR_HANDLE frontSrv(m_srvHeap->GetGPUDescriptorHandleForHeapStart(), 2, m_srvDescriptorSize);
        m_commandList->SetGraphicsRootDescriptorTable(1, frontSrv);

        m_commandList->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        m_commandList->DrawInstanced(3, 1, 0, 0);

        CD3DX12_RESOURCE_BARRIER toPresent = CD3DX12_RESOURCE_BARRIER::Transition(
            m_renderTargets[m_frameIndex].Get(),
            D3D12_RESOURCE_STATE_RENDER_TARGET,
            D3D12_RESOURCE_STATE_PRESENT);
        m_commandList->ResourceBarrier(1, &toPresent);
    }

    ThrowIfFailed(m_commandList->Close());
}

void IntervalShadingTetrahedron::OnDestroy()
{
    WaitForGpu();
    CloseHandle(m_fenceEvent);
}

void IntervalShadingTetrahedron::OnKeyDown(UINT8 key)
{
    const float rotationSpeed = 0.1f;
    const float zoomSpeed = 0.5f;
    
    switch (key)
    {
    case '1': m_constantBufferData.DebugMode = 0; break; // front
    case '2': m_constantBufferData.DebugMode = 1; break; // back
    case '3': m_constantBufferData.DebugMode = 2; break; // length
    case '4': m_constantBufferData.DebugMode = 3; break; // tau
    case '5': m_constantBufferData.DebugMode = 4; break; // T
    case '6': m_constantBufferData.DebugMode = 5; break; // fog/crystal
    case 'R': case 'r':
        ShuffleTets();
        break;

    case VK_LEFT:  m_cameraAngle -= rotationSpeed; break;
    case VK_RIGHT: m_cameraAngle += rotationSpeed; break;
    case VK_UP:    m_cameraElevation += rotationSpeed; break;
    case VK_DOWN:  m_cameraElevation -= rotationSpeed; break;
    case 'W': case 'w': m_cameraDistance = (std::max)(1.5f, m_cameraDistance - zoomSpeed); break;
    case 'S': case 's': m_cameraDistance = (std::min)(15.0f, m_cameraDistance + zoomSpeed); break;
    }
    
    // Keep angle in valid range
    if (m_cameraAngle > XM_2PI)
        m_cameraAngle -= XM_2PI;
    if (m_cameraAngle < 0)
        m_cameraAngle += XM_2PI;
    
    // Keep elevation in valid range (0 to 2PI) for seamless rotation
    if (m_cameraElevation > XM_2PI)
        m_cameraElevation -= XM_2PI;
    if (m_cameraElevation < 0)
        m_cameraElevation += XM_2PI;
}

bool IntervalShadingTetrahedron::LoadTetrahedralMesh(const std::wstring& path)
{
    m_vertices.clear();
    m_tetIndices.clear();

    std::ifstream file(path);
    if (!file.is_open())
    {
        return false;
    }

    std::string line;
    while (std::getline(file, line))
    {
        if (line.size() < 2)
            continue;

        if (line[0] == 'v' && line[1] == ' ')
        {
            std::stringstream ss(line.substr(2));
            float x, y, z;
            ss >> x >> y >> z;
            m_vertices.push_back(XMFLOAT4(x, y, z, 1.0f));
        }
        else if (line[0] == 't' && line[1] == ' ')
        {
            std::stringstream ss(line.substr(2));
            uint32_t a, b, c, d;
            ss >> a >> b >> c >> d;
            m_tetIndices.push_back(a);
            m_tetIndices.push_back(b);
            m_tetIndices.push_back(c);
            m_tetIndices.push_back(d);
        }
    }

    if (m_vertices.empty() || m_tetIndices.empty())
    {
        return false;
    }

    UploadBuffer(m_vertexBuffer.GetAddressOf(), m_vertices.data(), m_vertices.size() * sizeof(XMFLOAT4));
    UploadBuffer(m_tetBuffer.GetAddressOf(), m_tetIndices.data(), m_tetIndices.size() * sizeof(uint32_t));

    CD3DX12_RANGE range(0, 0);
    ThrowIfFailed(m_tetBuffer->Map(0, &range, reinterpret_cast<void**>(&m_tetBufferMapped)));

    // Build a centering/scaling model matrix so meshes land near the origin at a reasonable scale.
    XMFLOAT3 minP(FLT_MAX, FLT_MAX, FLT_MAX);
    XMFLOAT3 maxP(-FLT_MAX, -FLT_MAX, -FLT_MAX);
    for (auto& v : m_vertices)
    {
        minP.x = (std::min)(minP.x, v.x); minP.y = (std::min)(minP.y, v.y); minP.z = (std::min)(minP.z, v.z);
        maxP.x = (std::max)(maxP.x, v.x); maxP.y = (std::max)(maxP.y, v.y); maxP.z = (std::max)(maxP.z, v.z);
    }
    XMVECTOR minV = XMLoadFloat3(&minP);
    XMVECTOR maxV = XMLoadFloat3(&maxP);
    XMVECTOR center = 0.5f * (minV + maxV);

    XMFLOAT3 size;
    XMStoreFloat3(&size, maxV - minV);
    float maxExtent = (std::max)(size.x, (std::max)(size.y, size.z));
    float scale = (maxExtent > 0.0001f) ? (1.5f / maxExtent) : 1.0f;

    XMMATRIX model = XMMatrixScaling(scale, scale, scale) * XMMatrixTranslationFromVector(-center);
    XMStoreFloat4x4(&m_modelMatrix, XMMatrixTranspose(model));
    return true;
}

void IntervalShadingTetrahedron::CreateIntervalTargets()
{
    CD3DX12_HEAP_PROPERTIES heap(D3D12_HEAP_TYPE_DEFAULT);

    auto frontDesc = CD3DX12_RESOURCE_DESC::Tex2D(
        DXGI_FORMAT_R16_FLOAT,
        m_width,
        m_height,
        1, 1, 1, 0,
        D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
    D3D12_CLEAR_VALUE frontClear = {};
    frontClear.Format = frontDesc.Format;
    // Clear to large value so MIN blending stores the nearest front depth
    frontClear.Color[0] = frontClear.Color[1] = frontClear.Color[2] = frontClear.Color[3] = FLT_MAX;

    ThrowIfFailed(m_device->CreateCommittedResource(
        &heap,
        D3D12_HEAP_FLAG_NONE,
        &frontDesc,
        D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
        &frontClear,
        IID_PPV_ARGS(&m_frontRT)));

    CD3DX12_CPU_DESCRIPTOR_HANDLE frontHandle(m_rtvHeap->GetCPUDescriptorHandleForHeapStart(), FrameCount, m_rtvDescriptorSize);
    m_device->CreateRenderTargetView(m_frontRT.Get(), nullptr, frontHandle);
    m_frontState = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;

    auto backDesc = frontDesc;
    D3D12_CLEAR_VALUE backClear = {};
    backClear.Format = backDesc.Format;
    backClear.Color[0] = backClear.Color[1] = backClear.Color[2] = backClear.Color[3] = 0.0f;
    ThrowIfFailed(m_device->CreateCommittedResource(
        &heap,
        D3D12_HEAP_FLAG_NONE,
        &backDesc,
        D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
        &backClear,
        IID_PPV_ARGS(&m_backRT)));
    CD3DX12_CPU_DESCRIPTOR_HANDLE backHandle(m_rtvHeap->GetCPUDescriptorHandleForHeapStart(), FrameCount + 1, m_rtvDescriptorSize);
    m_device->CreateRenderTargetView(m_backRT.Get(), nullptr, backHandle);
    m_backState = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;

    auto opticalDesc = CD3DX12_RESOURCE_DESC::Tex2D(
        DXGI_FORMAT_R16_FLOAT,
        m_width,
        m_height,
        1, 1, 1, 0,
        D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
    D3D12_CLEAR_VALUE opticalClear = {};
    opticalClear.Format = opticalDesc.Format;
    opticalClear.Color[0] = opticalClear.Color[1] = opticalClear.Color[2] = opticalClear.Color[3] = 0.0f;

    ThrowIfFailed(m_device->CreateCommittedResource(
        &heap,
        D3D12_HEAP_FLAG_NONE,
        &opticalDesc,
        D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
        &opticalClear,
        IID_PPV_ARGS(&m_opticalDepthRT)));

    CD3DX12_CPU_DESCRIPTOR_HANDLE opticalHandle(m_rtvHeap->GetCPUDescriptorHandleForHeapStart(), FrameCount + 2, m_rtvDescriptorSize);
    m_device->CreateRenderTargetView(m_opticalDepthRT.Get(), nullptr, opticalHandle);
    m_opticalState = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
}

void IntervalShadingTetrahedron::CreateSrvHeap()
{
    CD3DX12_CPU_DESCRIPTOR_HANDLE cpuHandle(m_srvHeap->GetCPUDescriptorHandleForHeapStart());

    D3D12_SHADER_RESOURCE_VIEW_DESC vertsSrv = {};
    vertsSrv.ViewDimension = D3D12_SRV_DIMENSION_BUFFER;
    vertsSrv.Format = DXGI_FORMAT_UNKNOWN;
    vertsSrv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    vertsSrv.Buffer.NumElements = static_cast<UINT>(m_vertices.size());
    vertsSrv.Buffer.StructureByteStride = sizeof(XMFLOAT4);
    vertsSrv.Buffer.Flags = D3D12_BUFFER_SRV_FLAG_NONE;
    m_device->CreateShaderResourceView(m_vertexBuffer.Get(), &vertsSrv, cpuHandle);

    cpuHandle.Offset(1, m_srvDescriptorSize);
    D3D12_SHADER_RESOURCE_VIEW_DESC tetSrv = vertsSrv;
    tetSrv.Buffer.NumElements = static_cast<UINT>(m_tetIndices.size());
    tetSrv.Buffer.StructureByteStride = sizeof(uint32_t);
    m_device->CreateShaderResourceView(m_tetBuffer.Get(), &tetSrv, cpuHandle);

    cpuHandle.Offset(1, m_srvDescriptorSize);
    D3D12_SHADER_RESOURCE_VIEW_DESC texSrv = {};
    texSrv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
    texSrv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    texSrv.Texture2D.MipLevels = 1;

    texSrv.Format = DXGI_FORMAT_R16_FLOAT;
    m_device->CreateShaderResourceView(m_frontRT.Get(), &texSrv, cpuHandle);

    cpuHandle.Offset(1, m_srvDescriptorSize);
    m_device->CreateShaderResourceView(m_backRT.Get(), &texSrv, cpuHandle);

    cpuHandle.Offset(1, m_srvDescriptorSize);
    m_device->CreateShaderResourceView(m_opticalDepthRT.Get(), &texSrv, cpuHandle);
}

void IntervalShadingTetrahedron::BuildIntervalPipelineState()
{
    std::vector<BYTE> meshShader = ReadData(L"IntervalShadingMS.cso");
    std::vector<BYTE> pixelShader = ReadData(L"IntervalShadingPS.cso");

    CD3DX12_DESCRIPTOR_RANGE1 range;
    range.Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 2, 0); // vertices, tets

    CD3DX12_ROOT_PARAMETER1 params[2];
    params[0].InitAsConstantBufferView(0);
    params[1].InitAsDescriptorTable(1, &range, D3D12_SHADER_VISIBILITY_ALL);

    CD3DX12_STATIC_SAMPLER_DESC sampler(0, D3D12_FILTER_MIN_MAG_MIP_POINT);

    CD3DX12_VERSIONED_ROOT_SIGNATURE_DESC rsDesc;
    rsDesc.Init_1_1(_countof(params), params, 1, &sampler, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT);

    ComPtr<ID3DBlob> signature;
    ComPtr<ID3DBlob> error;
    ThrowIfFailed(D3D12SerializeVersionedRootSignature(&rsDesc, &signature, &error));
    ThrowIfFailed(m_device->CreateRootSignature(0, signature->GetBufferPointer(), signature->GetBufferSize(), IID_PPV_ARGS(&m_intervalRootSignature)));

    CD3DX12_BLEND_DESC blend(D3D12_DEFAULT);
    blend.IndependentBlendEnable = TRUE;
    // Front min
    blend.RenderTarget[0].BlendEnable = TRUE;
    blend.RenderTarget[0].BlendOp = D3D12_BLEND_OP_MIN;
    blend.RenderTarget[0].SrcBlend = D3D12_BLEND_ONE;
    blend.RenderTarget[0].DestBlend = D3D12_BLEND_ONE;
    blend.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP_MIN;
    blend.RenderTarget[0].SrcBlendAlpha = D3D12_BLEND_ONE;
    blend.RenderTarget[0].DestBlendAlpha = D3D12_BLEND_ONE;
    // Back max
    blend.RenderTarget[1].BlendEnable = TRUE;
    blend.RenderTarget[1].BlendOp = D3D12_BLEND_OP_MAX;
    blend.RenderTarget[1].SrcBlend = D3D12_BLEND_ONE;
    blend.RenderTarget[1].DestBlend = D3D12_BLEND_ONE;
    blend.RenderTarget[1].BlendOpAlpha = D3D12_BLEND_OP_MAX;
    blend.RenderTarget[1].SrcBlendAlpha = D3D12_BLEND_ONE;
    blend.RenderTarget[1].DestBlendAlpha = D3D12_BLEND_ONE;
    // Optical additive
    blend.RenderTarget[2].BlendEnable = TRUE;
    blend.RenderTarget[2].BlendOp = D3D12_BLEND_OP_ADD;
    blend.RenderTarget[2].SrcBlend = D3D12_BLEND_ONE;
    blend.RenderTarget[2].DestBlend = D3D12_BLEND_ONE;
    blend.RenderTarget[2].BlendOpAlpha = D3D12_BLEND_OP_ADD;
    blend.RenderTarget[2].SrcBlendAlpha = D3D12_BLEND_ONE;
    blend.RenderTarget[2].DestBlendAlpha = D3D12_BLEND_ONE;

    CD3DX12_DEPTH_STENCIL_DESC depth(D3D12_DEFAULT);
    depth.DepthEnable = FALSE;
    depth.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;

    D3D12_RT_FORMAT_ARRAY rtvFormats = {};
    rtvFormats.NumRenderTargets = 3;
    rtvFormats.RTFormats[0] = DXGI_FORMAT_R16_FLOAT;
    rtvFormats.RTFormats[1] = DXGI_FORMAT_R16_FLOAT;
    rtvFormats.RTFormats[2] = DXGI_FORMAT_R16_FLOAT;

    struct PipelineStateStream
    {
        CD3DX12_PIPELINE_STATE_STREAM_ROOT_SIGNATURE pRootSignature;
        CD3DX12_PIPELINE_STATE_STREAM_MS MS;
        CD3DX12_PIPELINE_STATE_STREAM_PS PS;
        CD3DX12_PIPELINE_STATE_STREAM_BLEND_DESC BlendState;
        CD3DX12_PIPELINE_STATE_STREAM_RASTERIZER RasterizerState;
        CD3DX12_PIPELINE_STATE_STREAM_DEPTH_STENCIL DepthStencilState;
        CD3DX12_PIPELINE_STATE_STREAM_RENDER_TARGET_FORMATS RTVFormats;
        CD3DX12_PIPELINE_STATE_STREAM_DEPTH_STENCIL_FORMAT DSVFormat;
        CD3DX12_PIPELINE_STATE_STREAM_SAMPLE_DESC SampleDesc;
        CD3DX12_PIPELINE_STATE_STREAM_SAMPLE_MASK SampleMask;
    } psoStream;

    psoStream.pRootSignature = m_intervalRootSignature.Get();
    psoStream.MS = CD3DX12_SHADER_BYTECODE(meshShader.data(), meshShader.size());
    psoStream.PS = CD3DX12_SHADER_BYTECODE(pixelShader.data(), pixelShader.size());
    psoStream.BlendState = blend;
    CD3DX12_RASTERIZER_DESC rasterizer(D3D12_DEFAULT);
    rasterizer.CullMode = D3D12_CULL_MODE_NONE;
    psoStream.RasterizerState = rasterizer;
    psoStream.DepthStencilState = depth;
    psoStream.RTVFormats = rtvFormats;
    psoStream.DSVFormat = DXGI_FORMAT_D32_FLOAT;
    psoStream.SampleDesc = DefaultSampleDesc();
    psoStream.SampleMask = UINT_MAX;

    D3D12_PIPELINE_STATE_STREAM_DESC streamDesc = {};
    streamDesc.pPipelineStateSubobjectStream = &psoStream;
    streamDesc.SizeInBytes = sizeof(psoStream);
    ThrowIfFailed(m_device->CreatePipelineState(&streamDesc, IID_PPV_ARGS(&m_intervalPipelineState)));
}

void IntervalShadingTetrahedron::BuildCompositePipelineState()
{
    std::vector<BYTE> vs = ReadData(L"IntervalCompositeVS.cso");
    std::vector<BYTE> ps = ReadData(L"IntervalCompositePS.cso");

    // Root signature for composite: CBV + SRVs for front/back/optical + sampler.
    CD3DX12_DESCRIPTOR_RANGE1 range;
    range.Init(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 3, 2); // t2,t3,t4

    CD3DX12_ROOT_PARAMETER1 params[2];
    params[0].InitAsConstantBufferView(0);
    params[1].InitAsDescriptorTable(1, &range, D3D12_SHADER_VISIBILITY_PIXEL);

    CD3DX12_STATIC_SAMPLER_DESC sampler(0, D3D12_FILTER_MIN_MAG_MIP_LINEAR, D3D12_TEXTURE_ADDRESS_MODE_CLAMP, D3D12_TEXTURE_ADDRESS_MODE_CLAMP, D3D12_TEXTURE_ADDRESS_MODE_CLAMP);

    CD3DX12_VERSIONED_ROOT_SIGNATURE_DESC rsDesc;
    rsDesc.Init_1_1(_countof(params), params, 1, &sampler, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT);

    ComPtr<ID3DBlob> signature;
    ComPtr<ID3DBlob> error;
    ThrowIfFailed(D3D12SerializeVersionedRootSignature(&rsDesc, &signature, &error));
    ThrowIfFailed(m_device->CreateRootSignature(0, signature->GetBufferPointer(), signature->GetBufferSize(), IID_PPV_ARGS(&m_compositeRootSignature)));

    // We consume three SRVs (front/back/optical) and output final color.
    D3D12_RT_FORMAT_ARRAY rtvFormats = {};
    rtvFormats.NumRenderTargets = 1;
    rtvFormats.RTFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;

    CD3DX12_DEPTH_STENCIL_DESC depth(D3D12_DEFAULT);
    depth.DepthEnable = FALSE;
    depth.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;

    struct GraphicsStream
    {
        CD3DX12_PIPELINE_STATE_STREAM_ROOT_SIGNATURE pRootSignature;
        CD3DX12_PIPELINE_STATE_STREAM_VS VS;
        CD3DX12_PIPELINE_STATE_STREAM_PS PS;
        CD3DX12_PIPELINE_STATE_STREAM_BLEND_DESC BlendState;
        CD3DX12_PIPELINE_STATE_STREAM_RASTERIZER RasterizerState;
        CD3DX12_PIPELINE_STATE_STREAM_DEPTH_STENCIL DepthStencilState;
        CD3DX12_PIPELINE_STATE_STREAM_RENDER_TARGET_FORMATS RTVFormats;
        CD3DX12_PIPELINE_STATE_STREAM_DEPTH_STENCIL_FORMAT DSVFormat;
        CD3DX12_PIPELINE_STATE_STREAM_SAMPLE_DESC SampleDesc;
        CD3DX12_PIPELINE_STATE_STREAM_SAMPLE_MASK SampleMask;
        CD3DX12_PIPELINE_STATE_STREAM_PRIMITIVE_TOPOLOGY PrimitiveTopology;
    } psoStream;

    psoStream.pRootSignature = m_compositeRootSignature.Get();
    psoStream.VS = CD3DX12_SHADER_BYTECODE(vs.data(), vs.size());
    psoStream.PS = CD3DX12_SHADER_BYTECODE(ps.data(), ps.size());
    psoStream.BlendState = CD3DX12_BLEND_DESC(D3D12_DEFAULT);
    CD3DX12_RASTERIZER_DESC compRasterizer(D3D12_DEFAULT);
    compRasterizer.CullMode = D3D12_CULL_MODE_NONE;
    psoStream.RasterizerState = compRasterizer;
    psoStream.DepthStencilState = depth;
    psoStream.RTVFormats = rtvFormats;
    psoStream.DSVFormat = DXGI_FORMAT_UNKNOWN;
    psoStream.SampleDesc = DefaultSampleDesc();
    psoStream.SampleMask = UINT_MAX;
    psoStream.PrimitiveTopology = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;

    D3D12_PIPELINE_STATE_STREAM_DESC streamDesc = {};
    streamDesc.pPipelineStateSubobjectStream = &psoStream;
    streamDesc.SizeInBytes = sizeof(psoStream);
    ThrowIfFailed(m_device->CreatePipelineState(&streamDesc, IID_PPV_ARGS(&m_compositePipelineState)));
}

void IntervalShadingTetrahedron::UploadBuffer(ID3D12Resource** destination, const void* data, size_t byteSize)
{
    CD3DX12_HEAP_PROPERTIES heap(D3D12_HEAP_TYPE_UPLOAD);
    CD3DX12_RESOURCE_DESC desc = CD3DX12_RESOURCE_DESC::Buffer(byteSize);

    ThrowIfFailed(m_device->CreateCommittedResource(
        &heap,
        D3D12_HEAP_FLAG_NONE,
        &desc,
        D3D12_RESOURCE_STATE_GENERIC_READ,
        nullptr,
        IID_PPV_ARGS(destination)));

    uint8_t* mapped = nullptr;
    CD3DX12_RANGE range(0, 0);
    ThrowIfFailed((*destination)->Map(0, &range, reinterpret_cast<void**>(&mapped)));
    std::memcpy(mapped, data, byteSize);
}

void IntervalShadingTetrahedron::UpdateConstants()
{
    float y = m_cameraDistance * sinf(m_cameraElevation);
    float r = m_cameraDistance * cosf(m_cameraElevation);
    float x = r * cosf(m_cameraAngle);
    float z = r * sinf(m_cameraAngle);

    XMVECTOR cameraPos = XMVectorSet(x, y, z, 1.0f);
    XMVECTOR target = XMVectorZero();
    XMVECTOR up = XMVectorSet(0.0f, 1.0f, 0.0f, 0.0f);

    if (cosf(m_cameraElevation) < 0.0f)
    {
        up = XMVectorSet(0.0f, -1.0f, 0.0f, 0.0f);
    }

    XMMATRIX model = XMMatrixIdentity();
    XMMATRIX view = XMMatrixLookAtLH(cameraPos, target, up);
    XMMATRIX proj = XMMatrixPerspectiveFovLH(XM_PIDIV4, m_aspectRatio, kNearPlane, 100.0f);
    XMMATRIX viewProj = view * proj;
    XMMATRIX invViewProj = XMMatrixInverse(nullptr, viewProj);

    m_constantBufferData.Model = m_modelMatrix;
    XMStoreFloat4x4(&m_constantBufferData.View, XMMatrixTranspose(view));
    XMStoreFloat4x4(&m_constantBufferData.Proj, XMMatrixTranspose(proj));
    XMStoreFloat4x4(&m_constantBufferData.ViewProj, XMMatrixTranspose(viewProj));
    XMStoreFloat4x4(&m_constantBufferData.InvViewProj, XMMatrixTranspose(invViewProj));
    m_constantBufferData.NearPlane = kNearPlane;
    m_constantBufferData.Density = kDefaultDensity;
    m_constantBufferData.TetCount = static_cast<uint32_t>(m_tetIndices.size() / 4);
    m_constantBufferData.RandomizeOrder = m_randomizeDrawOrder ? 1u : 0u;
    XMStoreFloat3(&m_constantBufferData.CameraPos, cameraPos);

    std::memcpy(m_cbvDataBegin + m_cbStride * m_frameIndex, &m_constantBufferData, sizeof(m_constantBufferData));
}

void IntervalShadingTetrahedron::MoveToNextFrame()
{
    const UINT64 currentFenceValue = m_fenceValues[m_frameIndex];
    ThrowIfFailed(m_commandQueue->Signal(m_fence.Get(), currentFenceValue));

    m_frameIndex = m_swapChain->GetCurrentBackBufferIndex();

    if (m_fence->GetCompletedValue() < m_fenceValues[m_frameIndex])
    {
        ThrowIfFailed(m_fence->SetEventOnCompletion(m_fenceValues[m_frameIndex], m_fenceEvent));
        WaitForSingleObjectEx(m_fenceEvent, INFINITE, FALSE);
    }

    m_fenceValues[m_frameIndex] = currentFenceValue + 1;
}

void IntervalShadingTetrahedron::WaitForGpu()
{
    ThrowIfFailed(m_commandQueue->Signal(m_fence.Get(), m_fenceValues[m_frameIndex]));
    ThrowIfFailed(m_fence->SetEventOnCompletion(m_fenceValues[m_frameIndex], m_fenceEvent));
    WaitForSingleObjectEx(m_fenceEvent, INFINITE, FALSE);
    m_fenceValues[m_frameIndex]++;
}

std::vector<BYTE> IntervalShadingTetrahedron::ReadData(const std::wstring& filename)
{
    std::ifstream file(filename, std::ios::binary | std::ios::ate);
    if (!file.is_open())
    {
        throw std::runtime_error("Failed to open shader file");
    }

    std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);

    std::vector<BYTE> buffer(size);
    if (!file.read(reinterpret_cast<char*>(buffer.data()), size))
    {
        throw std::runtime_error("Failed to read shader file");
    }

    return buffer;
}
void IntervalShadingTetrahedron::ShuffleTets()
{
    if (!m_tetBufferMapped || m_tetIndices.empty())
        return;

    const size_t tetCount = m_tetIndices.size() / 4;
    std::vector<size_t> order(tetCount);
    std::iota(order.begin(), order.end(), 0);
    static std::mt19937 rng{ std::random_device{}() };
    std::shuffle(order.begin(), order.end(), rng);

    std::vector<uint32_t> shuffled(m_tetIndices.size());
    for (size_t i = 0; i < tetCount; ++i)
    {
        const size_t src = order[i] * 4;
        const size_t dst = i * 4;
        shuffled[dst + 0] = m_tetIndices[src + 0];
        shuffled[dst + 1] = m_tetIndices[src + 1];
        shuffled[dst + 2] = m_tetIndices[src + 2];
        shuffled[dst + 3] = m_tetIndices[src + 3];
    }
    std::memcpy(m_tetBufferMapped, shuffled.data(), shuffled.size() * sizeof(uint32_t));
}
