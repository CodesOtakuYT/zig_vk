const builtin = @import("builtin");
const std = @import("std");
const c = @cImport({
    @cDefine("VK_NO_PROTOTYPES", {});
    @cInclude("vulkan/vulkan.h");
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_vulkan.h");
});

fn map_vk_error(result: c.VkResult) !void {
    if (result >= 0) return;
    return switch (result) {
        else => error.UnknownVkResult,
    };
}

const Instance = struct {
    const Self = @This();
    const Dispatch = struct {
        DestroyInstance: std.meta.Child(c.PFN_vkDestroyInstance) = undefined,
        EnumeratePhysicalDevices: std.meta.Child(c.PFN_vkEnumeratePhysicalDevices) = undefined,
        GetPhysicalDeviceQueueFamilyProperties: std.meta.Child(c.PFN_vkGetPhysicalDeviceQueueFamilyProperties) = undefined,
        CreateDevice: std.meta.Child(c.PFN_vkCreateDevice) = undefined,
        GetDeviceProcAddr: std.meta.Child(c.PFN_vkGetDeviceProcAddr) = undefined,
    };

    handle: c.VkInstance,
    allocation_callbacks: ?*c.VkAllocationCallbacks,
    vulkan_library: VulkanLibrary,
    dispatch: Dispatch,

    fn init(vulkan_library: VulkanLibrary, extensions: [][*c]const u8, allocation_callbacks: ?*c.VkAllocationCallbacks) !Self {
        const create_info = std.mem.zeroInit(c.VkInstanceCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .enabledExtensionCount = @as(u32, @intCast(extensions.len)),
            .ppEnabledExtensionNames = extensions.ptr,
            .flags = switch (builtin.target.os.tag) {
                .macos, .ios, .tvos => c.VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
                else => 0,
            },
        });
        const create_instance = try vulkan_library.get_proc(c.PFN_vkCreateInstance, null, "vkCreateInstance");
        var handle: c.VkInstance = undefined;
        try map_vk_error(create_instance(&create_info, allocation_callbacks, &handle));

        return .{
            .handle = handle,
            .allocation_callbacks = allocation_callbacks,
            .vulkan_library = vulkan_library,
            .dispatch = try vulkan_library.load(Dispatch, "", handle),
        };
    }

    fn deinit(self: Self) void {
        self.dispatch.DestroyInstance(self.handle, self.allocation_callbacks);
    }

    fn get_proc(self: Self, comptime PFN: type, name: [*c]const u8) !std.meta.Child(PFN) {
        return self.vulkan_library.get_proc(PFN, self.handle, name);
    }

    fn get_device_proc(self: Self, comptime PFN: type, device: c.VkDevice, name: [*c]const u8) !std.meta.Child(PFN) {
        if (self.dispatch.GetDeviceProcAddr(device, name)) |proc| {
            return @ptrCast(proc);
        } else {
            c.SDL_Log("%s", name);
            return error.GetDeviceProcAddr;
        }
    }

    fn load(self: @This(), comptime DeviceDispatch: type, comptime suffix: []const u8, device: c.VkDevice) !DeviceDispatch {
        var dispatch = DeviceDispatch{};
        inline for (@typeInfo(DeviceDispatch).Struct.fields) |field| {
            @field(dispatch, field.name) = try self.get_device_proc(?field.type, device, "vk" ++ field.name ++ suffix);
        }
        return dispatch;
    }

    fn enumerate_physical_devices(self: Self, allocator: std.mem.Allocator) ![]c.VkPhysicalDevice {
        var count: u32 = undefined;
        try map_vk_error(self.dispatch.EnumeratePhysicalDevices(self.handle, &count, null));
        var allocation = try allocator.alloc(c.VkPhysicalDevice, count);
        errdefer allocator.free(allocation);
        try map_vk_error(self.dispatch.EnumeratePhysicalDevices(self.handle, &count, allocation.ptr));
        return allocation;
    }

    fn get_physical_device_queue_family_properties(self: Self, physical_device: c.VkPhysicalDevice, allocator: std.mem.Allocator) ![]c.VkQueueFamilyProperties {
        var count: u32 = undefined;
        self.dispatch.GetPhysicalDeviceQueueFamilyProperties(physical_device, &count, null);
        var allocation = try allocator.alloc(c.VkQueueFamilyProperties, count);
        errdefer allocator.free(allocation);
        self.dispatch.GetPhysicalDeviceQueueFamilyProperties(physical_device, &count, allocation.ptr);
        return allocation;
    }

    fn request_adapter(self: Self, allocator: std.mem.Allocator, maybe_surface: ?Surface) !Adapter {
        const physical_devices = try self.enumerate_physical_devices(allocator);
        defer allocator.free(physical_devices);

        for (physical_devices) |physical_device| {
            const queue_families_properties = try self.get_physical_device_queue_family_properties(physical_device, allocator);
            defer allocator.free(queue_families_properties);
            for (queue_families_properties, 0..) |queue_family_properties, queue_family_index| {
                var is_presentation_supported = true;
                if (maybe_surface) |surface| {
                    is_presentation_supported = try surface.get_presentation_support(physical_device, @intCast(queue_family_index));
                }
                if (queue_family_properties.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == c.VK_QUEUE_GRAPHICS_BIT and is_presentation_supported) {
                    return .{
                        .instance = self,
                        .physical_device = physical_device,
                        .queue_family_index = @intCast(queue_family_index),
                    };
                }
            }
        }

        return error.NoSuitableQueueFamily;
    }
};

const Window = struct {
    const Self = @This();

    handle: *c.SDL_Window,

    fn init(title: [*c]const u8, width: c_int, height: c_int) !Self {
        const handle = c.SDL_CreateWindow(title, c.SDL_WINDOWPOS_UNDEFINED, c.SDL_WINDOWPOS_UNDEFINED, width, height, c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_RESIZABLE);
        if (handle == null) {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "%s", c.SDL_GetError());
            return error.SDLCreateWindow;
        }
        return .{
            .handle = handle.?,
        };
    }

    fn deinit(self: Self) void {
        c.SDL_DestroyWindow(self.handle);
    }

    fn show(self: Self) void {
        c.SDL_ShowWindow(self.handle);
    }

    fn get_extent(self: Self) c.VkExtent2D {
        var width: c_int = undefined;
        var height: c_int = undefined;
        c.SDL_Vulkan_GetDrawableSize(self.handle, &width, &height);
        return .{
            .width = @intCast(width),
            .height = @intCast(height),
        };
    }

    fn get_instance_extensions(self: Self, allocator: std.mem.Allocator) ![][*c]const u8 {
        var extensions_count: c_uint = undefined;
        if (c.SDL_Vulkan_GetInstanceExtensions(self.handle, &extensions_count, null) == c.SDL_FALSE) {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "%s", c.SDL_GetError());
            return error.SDLVulkanGetInstanceExtensionsCount;
        }
        const additional_extension_count = switch (builtin.target.os.tag) {
            .macos, .ios, .tvos => 1,
            else => 0,
        };
        const extensions = try allocator.alloc([*c]const u8, extensions_count + additional_extension_count);
        errdefer allocator.free(extensions);
        if (c.SDL_Vulkan_GetInstanceExtensions(self.handle, &extensions_count, extensions.ptr) == c.SDL_FALSE) {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "%s", c.SDL_GetError());
            return error.SDLVulkanGetInstanceExtensions;
        }
        if (additional_extension_count == 1) {
            extensions[extensions_count] = c.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
        }
        return extensions;
    }
};

const SDL = struct {
    const Self = @This();

    fn init() !Self {
        if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "%s", c.SDL_GetError());
            return error.SDLInitVideo;
        }

        return .{};
    }

    fn deinit(self: Self) void {
        _ = self;
        c.SDL_Quit();
    }

    fn poll_event(self: Self) ?c.SDL_Event {
        _ = self;
        var event: c.SDL_Event = undefined;
        if (c.SDL_PollEvent(&event) == c.SDL_TRUE) {
            return event;
        } else {
            return null;
        }
    }
};

const VulkanLibrary = struct {
    const Self = @This();

    get_instance_proc_addr: std.meta.Child(c.PFN_vkGetInstanceProcAddr),

    fn init() !Self {
        if (c.SDL_Vulkan_LoadLibrary(null) != 0) {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "%s", c.SDL_GetError());
            return error.SDLVulkanLoadLibrary;
        }
        if (c.SDL_Vulkan_GetVkGetInstanceProcAddr()) |proc| {
            return .{
                .get_instance_proc_addr = @ptrCast(proc),
            };
        } else {
            return error.SDLVulkanGetVkGetInstanceProcAddr;
        }
    }

    fn deinit(self: Self) void {
        _ = self;
        c.SDL_Vulkan_UnloadLibrary();
    }

    fn get_proc(self: Self, comptime PFN: type, instance: c.VkInstance, name: [*c]const u8) !std.meta.Child(PFN) {
        if (self.get_instance_proc_addr(instance, name)) |proc| {
            return @ptrCast(proc);
        } else {
            return error.GetInstanceProcAddr;
        }
    }

    fn load(self: VulkanLibrary, comptime Dispatch: type, comptime suffix: []const u8, instance: c.VkInstance) !Dispatch {
        var dispatch = Dispatch{};
        inline for (@typeInfo(Dispatch).Struct.fields) |field| {
            @field(dispatch, field.name) = try self.get_proc(?field.type, instance, "vk" ++ field.name ++ suffix);
        }
        return dispatch;
    }
};

const Surface = struct {
    const Self = @This();

    handle: c.VkSurfaceKHR,
    extension: SurfaceExtension,
    window: Window,

    fn deinit(self: Self) void {
        self.extension.dispatch.DestroySurface(self.extension.instance.handle, self.handle, null);
    }

    fn get_presentation_support(self: Self, physical_device: c.VkPhysicalDevice, queue_family_index: u32) !bool {
        var is_supported: c.VkBool32 = undefined;
        try map_vk_error(self.extension.dispatch.GetPhysicalDeviceSurfaceSupport(physical_device, queue_family_index, self.handle, &is_supported));
        return is_supported == c.VK_TRUE;
    }

    fn get_capabilities(self: Self, adapter: Adapter) !c.VkSurfaceCapabilitiesKHR {
        var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try map_vk_error(self.extension.dispatch.GetPhysicalDeviceSurfaceCapabilities(adapter.physical_device, self.handle, &capabilities));
        return capabilities;
    }
};

const SurfaceExtension = struct {
    const Self = @This();
    const Dispatch = struct {
        DestroySurface: std.meta.Child(c.PFN_vkDestroySurfaceKHR) = undefined,
        GetPhysicalDeviceSurfaceSupport: std.meta.Child(c.PFN_vkGetPhysicalDeviceSurfaceSupportKHR) = undefined,
        GetPhysicalDeviceSurfaceCapabilities: std.meta.Child(c.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR) = undefined,
    };

    dispatch: Dispatch,
    instance: Instance,

    fn load(instance: Instance) !Self {
        return .{
            .dispatch = try instance.vulkan_library.load(Dispatch, "KHR", instance.handle),
            .instance = instance,
        };
    }

    fn create_surface(self: Self, window: Window) !Surface {
        var handle: c.VkSurfaceKHR = undefined;
        if (c.SDL_Vulkan_CreateSurface(window.handle, self.instance.handle, &handle) == c.SDL_FALSE) {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "%s", c.SDL_GetError());
            return error.SDLVulkanCreateSurface;
        }
        return .{
            .handle = handle,
            .extension = self,
            .window = window,
        };
    }
};

const Adapter = struct {
    const Self = @This();

    instance: Instance,
    physical_device: c.VkPhysicalDevice,
    queue_family_index: u32,

    fn request_device(self: Self, allocation_callbacks: ?*c.VkAllocationCallbacks) !Device {
        const queue_priorities = [_]f32{1.0};
        const queue_create_infos = [_]c.VkDeviceQueueCreateInfo{
            std.mem.zeroInit(c.VkDeviceQueueCreateInfo, .{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = self.queue_family_index,
                .queueCount = @as(u32, @intCast(queue_priorities.len)),
                .pQueuePriorities = &queue_priorities,
            }),
        };

        const extensions = switch (builtin.target.os.tag) {
            .macos, .ios, .tvos => [_][*c]const u8{
                c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
                c.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
            },
            else => [_][*c]const u8{
                c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
            },
        };

        const create_info = std.mem.zeroInit(c.VkDeviceCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = @as(u32, queue_create_infos.len),
            .pQueueCreateInfos = &queue_create_infos,
            .enabledExtensionCount = extensions.len,
            .ppEnabledExtensionNames = &extensions,
        });

        var handle: c.VkDevice = undefined;
        try map_vk_error(self.instance.dispatch.CreateDevice(
            self.physical_device,
            &create_info,
            allocation_callbacks,
            &handle,
        ));

        const dispatch = try self.instance.load(Device.Dispatch, "", handle);
        var queue: c.VkQueue = undefined;
        dispatch.GetDeviceQueue(handle, self.queue_family_index, 0, &queue);

        return .{
            .handle = handle,
            .allocation_callbacks = allocation_callbacks,
            .adapter = self,
            .dispatch = dispatch,
            .queue = queue,
        };
    }
};

const Device = struct {
    const Self = @This();

    const Dispatch = struct {
        DestroyDevice: std.meta.Child(c.PFN_vkDestroyDevice) = undefined,
        GetDeviceQueue: std.meta.Child(c.PFN_vkGetDeviceQueue) = undefined,
        CreateImageView: std.meta.Child(c.PFN_vkCreateImageView) = undefined,
        DestroyImageView: std.meta.Child(c.PFN_vkDestroyImageView) = undefined,
    };

    handle: c.VkDevice,
    allocation_callbacks: ?*c.VkAllocationCallbacks,
    adapter: Adapter,
    dispatch: Dispatch,
    queue: c.VkQueue,

    fn deinit(self: Self) void {
        self.dispatch.DestroyDevice(self.handle, self.allocation_callbacks);
    }

    fn create_image_view(self: Self, create_info: c.VkImageViewCreateInfo, allocation_callbacks: ?*c.VkAllocationCallbacks) !c.VkImageView {
        var handle: c.VkImageView = undefined;
        try map_vk_error(self.dispatch.CreateImageView(self.handle, &create_info, allocation_callbacks, &handle));
        return handle;
    }
};

const SwapchainExtension = struct {
    const Self = @This();
    const Dispatch = struct {
        CreateSwapchain: std.meta.Child(c.PFN_vkCreateSwapchainKHR) = undefined,
        DestroySwapchain: std.meta.Child(c.PFN_vkDestroySwapchainKHR) = undefined,
        GetSwapchainImages: std.meta.Child(c.PFN_vkGetSwapchainImagesKHR) = undefined,
    };

    dispatch: Dispatch,
    device: Device,

    fn load(device: Device) !Self {
        return .{
            .dispatch = try device.adapter.instance.load(Dispatch, "KHR", device.handle),
            .device = device,
        };
    }

    fn create_swapchain(self: Self, surface: Surface, allocation_callbacks: ?*c.VkAllocationCallbacks, allocator: std.mem.Allocator, maybe_old_swapchain: ?*Swapchain) !?Swapchain {
        var surface_capabilities = try surface.get_capabilities(self.device.adapter);
        const queue_family_indices = [_]u32{self.device.adapter.queue_family_index};

        const image_extent = if (surface_capabilities.currentExtent.width == std.math.maxInt(u32))
            surface.window.get_extent()
        else
            surface_capabilities.currentExtent;

        if (image_extent.width == 0 or image_extent.height == 0) {
            if (maybe_old_swapchain) |old_swapchain| {
                old_swapchain.deinit();
            }
            return null;
        }

        const create_info = std.mem.zeroInit(c.VkSwapchainCreateInfoKHR, .{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = surface.handle,
            .presentMode = c.VK_PRESENT_MODE_FIFO_KHR,
            .preTransform = surface_capabilities.currentTransform,
            .imageFormat = c.VK_FORMAT_B8G8R8A8_SRGB,
            .imageColorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
            .clipped = c.VK_TRUE,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .queueFamilyIndexCount = queue_family_indices.len,
            .pQueueFamilyIndices = &queue_family_indices,
            .imageSharingMode = if (queue_family_indices.len == 1) c.VK_SHARING_MODE_EXCLUSIVE else c.VK_SHARING_MODE_CONCURRENT,
            .imageArrayLayers = 1,
            .imageExtent = image_extent,
            .minImageCount = @min(
                surface_capabilities.minImageCount + 1,
                if (surface_capabilities.maxImageCount == 0) std.math.maxInt(u32) else surface_capabilities.maxImageCount,
            ),
            .oldSwapchain = if (maybe_old_swapchain) |old_swapchain| old_swapchain.handle else null,
        });
        var handle: c.VkSwapchainKHR = undefined;
        try map_vk_error(self.dispatch.CreateSwapchain(self.device.handle, &create_info, allocation_callbacks, &handle));
        errdefer self.dispatch.DestroySwapchain(self.device.handle, handle, allocation_callbacks);

        var images_count: u32 = undefined;
        try map_vk_error(self.dispatch.GetSwapchainImages(self.device.handle, handle, &images_count, null));

        var images: []c.VkImage = undefined;
        var views: []c.VkImageView = undefined;

        if (maybe_old_swapchain) |*old_swapchain| {
            if (old_swapchain.*.images.len == images_count) {
                // Reuse the allocations
                images = old_swapchain.*.images;
                views = old_swapchain.*.views;
            } else {
                // Reallocate
                images = try allocator.realloc(old_swapchain.*.images, images_count);
                views = try allocator.realloc(old_swapchain.*.views, images_count);
            }
            old_swapchain.*.is_retired = true;
            old_swapchain.*.deinit();
        } else {
            // Allocate
            images = try allocator.alloc(c.VkImage, images_count);
            views = try allocator.alloc(c.VkImageView, images_count);
        }
        errdefer allocator.free(images);
        errdefer allocator.free(views);

        try map_vk_error(self.dispatch.GetSwapchainImages(self.device.handle, handle, &images_count, images.ptr));

        for (images, views) |image, *view| {
            view.* = try self.device.create_image_view(std.mem.zeroInit(c.VkImageViewCreateInfo, .{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = image,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = create_info.imageFormat,
                .subresourceRange = c.VkImageSubresourceRange{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseArrayLayer = 0,
                    .baseMipLevel = 0,
                    .layerCount = 1,
                    .levelCount = 1,
                },
            }), null);
        }

        return .{
            .handle = handle,
            .extension = self,
            .allocation_callbacks = allocation_callbacks,
            .images = images,
            .views = views,
            .allocator = allocator,
        };
    }
};

const Swapchain = struct {
    const Self = @This();

    handle: c.VkSwapchainKHR,
    extension: SwapchainExtension,
    allocation_callbacks: ?*c.VkAllocationCallbacks,
    allocator: std.mem.Allocator,
    images: []c.VkImage,
    views: []c.VkImageView,
    is_retired: bool = false,

    fn deinit(self: Self) void {
        for (self.views) |view| {
            self.extension.device.dispatch.DestroyImageView(self.extension.device.handle, view, self.allocation_callbacks);
        }
        if (!self.is_retired) {
            self.allocator.free(self.views);
            self.allocator.free(self.images);
        }
        self.extension.dispatch.DestroySwapchain(self.extension.device.handle, self.handle, self.allocation_callbacks);
    }
};

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = true,
    }){};
    defer std.debug.assert(general_purpose_allocator.deinit() == .ok);
    const allocator = general_purpose_allocator.allocator();

    const sdl = try SDL.init();
    defer sdl.deinit();

    const vulkan_library = try VulkanLibrary.init();
    defer vulkan_library.deinit();

    const window = try Window.init("Salam", 800, 600);
    defer window.deinit();

    const extensions = try window.get_instance_extensions(allocator);
    defer allocator.free(extensions);

    const instance = try Instance.init(vulkan_library, extensions, null);
    defer instance.deinit();

    const surface_extension = try SurfaceExtension.load(instance);

    var maybe_surface: ?Surface = null;
    if (builtin.target.abi != .android) {
        maybe_surface = try surface_extension.create_surface(window);
    }
    defer if (maybe_surface) |surface| {
        surface.deinit();
    };

    const adapter = try instance.request_adapter(allocator, maybe_surface);
    const device = try adapter.request_device(null);
    defer device.deinit();

    const swapchain_extension = try SwapchainExtension.load(device);
    var maybe_swapchain: ?Swapchain = null;
    defer if (maybe_swapchain) |swapchain| {
        swapchain.deinit();
    };

    if (maybe_surface) |surface| {
        maybe_swapchain = try swapchain_extension.create_swapchain(
            surface,
            null,
            allocator,
            null,
        );
    }

    window.show();
    main_loop: while (true) {
        while (sdl.poll_event()) |event| {
            switch (event.type) {
                c.SDL_QUIT => break :main_loop,
                c.SDL_WINDOWEVENT => switch (event.window.event) {
                    c.SDL_WINDOWEVENT_RESIZED => if (maybe_surface) |surface| {
                        maybe_swapchain = try swapchain_extension.create_swapchain(
                            surface,
                            null,
                            allocator,
                            if (maybe_swapchain) |*swapchain| swapchain else null,
                        );
                    },
                    else => {},
                },
                c.SDL_APP_DIDENTERFOREGROUND => {
                    if (maybe_surface == null) {
                        const surface = try surface_extension.create_surface(window);
                        maybe_surface = surface;
                        maybe_swapchain = try swapchain_extension.create_swapchain(
                            surface,
                            null,
                            allocator,
                            null,
                        );
                    }
                },
                c.SDL_APP_WILLENTERBACKGROUND => {
                    if (maybe_surface) |surface| {
                        maybe_surface = null;
                        if (maybe_swapchain) |swapchain| {
                            swapchain.deinit();
                        }
                        surface.deinit();
                    }
                },
                else => {},
            }
        }
    }
}
