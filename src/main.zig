const std = @import("std");
const c = @cImport({
    @cDefine("VK_NO_PROTOTYPES", {});
    @cInclude("vulkan/vulkan.h");
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_vulkan.h");
});

const Instance = struct {
    const Self = @This();
    const Dispatch = struct {
        DestroyInstance: std.meta.Child(c.PFN_vkDestroyInstance) = undefined,
        EnumeratePhysicalDevices: std.meta.Child(c.PFN_vkEnumeratePhysicalDevices) = undefined,
        GetPhysicalDeviceQueueFamilyProperties: std.meta.Child(c.PFN_vkGetPhysicalDeviceQueueFamilyProperties) = undefined,
        DestroySurfaceKHR: std.meta.Child(c.PFN_vkDestroySurfaceKHR) = undefined,
        GetPhysicalDeviceSurfaceSupportKHR: std.meta.Child(c.PFN_vkGetPhysicalDeviceSurfaceSupportKHR) = undefined,

        fn init(vulkan_library: VulkanLibrary, instance: c.VkInstance) !@This() {
            var self = @This(){};
            inline for (@typeInfo(@This()).Struct.fields) |field| {
                const proc_name = "vk" ++ field.name;
                const typ = ?field.type;
                @field(self, field.name) = try vulkan_library.get_proc(typ, instance, proc_name);
            }
            return self;
        }
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
        });
        const create_instance = try vulkan_library.get_proc(c.PFN_vkCreateInstance, null, "vkCreateInstance");
        var handle: c.VkInstance = undefined;
        if (create_instance(&create_info, allocation_callbacks, &handle) < 0) {
            return error.VkCreateInstance;
        }

        return .{
            .handle = handle,
            .allocation_callbacks = allocation_callbacks,
            .vulkan_library = vulkan_library,
            .dispatch = try Dispatch.init(vulkan_library, handle),
        };
    }

    fn deinit(self: Self) void {
        self.dispatch.DestroyInstance(self.handle, self.allocation_callbacks);
    }

    fn get_proc(self: Self, comptime PFN: type, name: [*c]const u8) !std.meta.Child(PFN) {
        return self.vulkan_library.get_proc(PFN, self.handle, name);
    }

    fn create_surface(self: Self, window: Window) !Surface {
        return Surface.init(window, self);
    }

    fn enumerate_physical_devices(self: Self, allocator: std.mem.Allocator) ![]c.VkPhysicalDevice {
        var count: u32 = undefined;
        if (self.dispatch.EnumeratePhysicalDevices(self.handle, &count, null) < 0) {
            return error.VkEnumeratePhysicalDevicesCount;
        }
        var allocation = try allocator.alloc(c.VkPhysicalDevice, count);
        errdefer allocator.free(allocation);
        if (self.dispatch.EnumeratePhysicalDevices(self.handle, &count, allocation.ptr) < 0) {
            return error.VkEnumeratePhysicalDevices;
        }
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
        const handle = c.SDL_CreateWindow(title, c.SDL_WINDOWPOS_UNDEFINED, c.SDL_WINDOWPOS_UNDEFINED, width, height, c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_HIDDEN);
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

    fn get_instance_extensions(self: Self, allocator: std.mem.Allocator) ![][*c]const u8 {
        var extensions_count: c_uint = undefined;
        if (c.SDL_Vulkan_GetInstanceExtensions(self.handle, &extensions_count, null) == c.SDL_FALSE) {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "%s", c.SDL_GetError());
            return error.SDLVulkanGetInstanceExtensionsCount;
        }
        const extensions = try allocator.alloc([*c]const u8, extensions_count);
        errdefer allocator.free(extensions);
        if (c.SDL_Vulkan_GetInstanceExtensions(self.handle, &extensions_count, extensions.ptr) == c.SDL_FALSE) {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "%s", c.SDL_GetError());
            return error.SDLVulkanGetInstanceExtensions;
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

    fn get_platform(self: Self) []const u8 {
        _ = self;
        return std.mem.sliceTo(c.SDL_GetPlatform(), 0);
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
};

const Surface = struct {
    const Self = @This();

    handle: c.VkSurfaceKHR,
    instance: Instance,

    fn init(window: Window, instance: Instance) !Self {
        var handle: c.VkSurfaceKHR = undefined;
        if (c.SDL_Vulkan_CreateSurface(window.handle, instance.handle, &handle) == c.SDL_FALSE) {
            return error.SDLVulkanCreateSurface;
        }
        return .{
            .handle = handle,
            .instance = instance,
        };
    }

    fn deinit(self: Self) void {
        self.instance.dispatch.DestroySurfaceKHR(self.instance.handle, self.handle, null);
    }

    fn get_presentation_support(self: Self, physical_device: c.VkPhysicalDevice, queue_family_index: u32) !bool {
        var is_supported: c.VkBool32 = undefined;
        if (self.instance.dispatch.GetPhysicalDeviceSurfaceSupportKHR(physical_device, queue_family_index, self.handle, &is_supported) < 0) {
            return error.GetPhysicalDeviceSurfaceSupportKHR;
        }
        return is_supported == c.VK_TRUE;
    }
};

const Adapter = struct {
    const Self = @This();

    instance: Instance,
    physical_device: c.VkPhysicalDevice,
    queue_family_index: u32,
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

    var maybe_surface: ?Surface = null;
    if (!std.mem.eql(u8, sdl.get_platform(), "Android")) {
        maybe_surface = try instance.create_surface(window);
    }
    defer if (maybe_surface) |surface| {
        surface.deinit();
    };

    const adapter = try instance.request_adapter(allocator, maybe_surface);
    _ = adapter;

    window.show();
    main_loop: while (true) {
        while (sdl.poll_event()) |event| {
            switch (event.type) {
                c.SDL_QUIT => break :main_loop,
                c.SDL_APP_DIDENTERFOREGROUND => {
                    maybe_surface = try instance.create_surface(window);
                },
                c.SDL_APP_WILLENTERBACKGROUND => {
                    if (maybe_surface) |surface| {
                        maybe_surface = null;
                        surface.deinit();
                    }
                },
                else => {},
            }
        }
    }
}
