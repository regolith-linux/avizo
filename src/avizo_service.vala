using Gtk;
using GtkLayerShell;

[CCode (cname = "gdk_wayland_display_get_type")]
extern Type get_wayland_type();

[GtkTemplate (ui = "/org/danb/avizo/ui/avizo.ui")]
public class AvizoWindow : Gtk.Window
{
	private string _image_path = "";
	public string image_path
	{
		set
		{
			if (value != "")
			{
				_image_path = value;
				_image_resource = "";
				update_image();
			}
		}
	}

	private string _image_resource = "";
	public string image_resource
	{
		set
		{
			if (value != "")
			{
				_image_resource = value;
				_image_path = "";
				update_image();
			}
		}
	}

	public double image_opacity
	{
		get
		{
			return image.opacity;
		}
		set
		{
			image.opacity = value;
		}
	}

	public double progress { get; set; }

	public int monitor { get; set; }

	private int _width = 248;
	public int width
	{
		get
		{
			return _width;
		}

		set
		{
			_width = value;

			set_size_request(_width, _height);
		}
	}

	private int _height = 232;
	public int height
	{
		get
		{
			return _height;
		}

		set
		{
			_height = value;

			set_size_request(_width, _height);
		}
	}

	public int padding { get; set; }
	public double x_offset { get; set; }
	public double y_offset { get; set; }
	public int border_radius { get; set; }
	public new int border_width { get; set; }

	public int block_height { get; set; }
	public int block_spacing { get; set; }
	public int block_count { get; set; }

	public double fade_in { get; set; }
	public double fade_out { get; set; }

	public Gdk.RGBA background { get; set; default = Gdk.RGBA(); }
	public Gdk.RGBA border_color { get; set; default = Gdk.RGBA(); }
	public Gdk.RGBA bar_fg_color { get; set; default = Gdk.RGBA(); }
	public Gdk.RGBA bar_bg_color { get; set; default = Gdk.RGBA(); }

	private new double opacity = 0;
	private bool is_fade_in = true;
	private int64 prev_frame_time = 0;
	private uint prev_callback_id = 0;
	private bool on_focused_output = false;
	private uint place_timeout_id = 0;
	private bool has_alpha = false;

	// Emitted once the window is hidden at the end of its fade-out.
	public signal void faded_out();

	[GtkChild]
	private unowned Gtk.Image image;

	public AvizoWindow()
	{
		// On X11 a popup window is left alone by the window manager: no frame,
		// no focus, and it stays exactly where and how big it is put.
		Object(type: is_wayland(Gdk.Display.get_default()) ? Gtk.WindowType.TOPLEVEL : Gtk.WindowType.POPUP);

		var screen = get_screen();
		var visual = screen.get_rgba_visual();
		if (visual != null && screen.is_composited())
		{
			set_visual(visual);
			has_alpha = true;
		}

		draw.connect(on_draw);
		notify["scale-factor"].connect(update_image);
	}

	// Renders the image at the output's scale factor, so that it stays sharp on
	// scaled outputs (GTK draws a plain pixbuf at scale 1 and stretches it).
	private void update_image()
	{
		int scale = int.max(get_scale_factor(), 1);
		Gdk.Pixbuf? pixbuf = null;

		try
		{
			if (_image_resource != "")
			{
				var path = @"/org/danb/avizo/data/images/$(_image_resource)";
				var natural = new Gdk.Pixbuf.from_resource(path + ".png");
				pixbuf = natural;
				if (scale > 1)
				{
					try
					{
						pixbuf = render_like(path + ".svg", natural, scale);
					}
					catch (Error e)
					{
						pixbuf = natural.scale_simple(natural.width * scale,
							natural.height * scale, Gdk.InterpType.BILINEAR);
					}
				}
			}
			else if (_image_path != "")
			{
				int width, height;
				if (Gdk.Pixbuf.get_file_info(_image_path, out width, out height) == null)
				{
					throw new FileError.INVAL(@"unknown image format: $(_image_path)");
				}
				pixbuf = new Gdk.Pixbuf.from_file_at_scale(_image_path,
					width * scale, height * scale, true);
			}
		}
		catch (Error e)
		{
			warning("Could not load image: %s", e.message);
			return;
		}

		if (pixbuf != null)
		{
			image.set_from_surface(Gdk.cairo_surface_create_from_pixbuf(pixbuf, scale, null));
		}
	}

	// Renders the SVG source of a built-in image so that it lines up with the
	// PNG at scale times its size: the PNGs are renders of the SVGs cropped to
	// different margins, so match the drawn (non-transparent) part of both.
	private static Gdk.Pixbuf render_like(string svg_path, Gdk.Pixbuf png, int scale) throws Error
	{
		var png_box = content_box(png);
		var svg_natural = new Gdk.Pixbuf.from_resource(svg_path);
		var svg_natural_box = content_box(svg_natural);
		double factor = (double) (png_box.width * scale) / svg_natural_box.width;

		var svg = new Gdk.Pixbuf.from_resource_at_scale(svg_path,
			(int) Math.round(svg_natural.width * factor),
			(int) Math.round(svg_natural.height * factor), true);
		var svg_box = content_box(svg);

		var result = new Gdk.Pixbuf(Gdk.Colorspace.RGB, true, 8,
			png.width * scale, png.height * scale);
		result.fill(0);
		int x = png_box.x * scale;
		int y = png_box.y * scale;
		int width = int.min(svg_box.width, result.width - x);
		int height = int.min(svg_box.height, result.height - y);
		svg.copy_area(svg_box.x, svg_box.y, width, height, result, x, y);
		return result;
	}

	// The smallest rectangle holding every pixel that is not fully transparent.
	private static Gdk.Rectangle content_box(Gdk.Pixbuf pixbuf)
	{
		var box = Gdk.Rectangle() { x = 0, y = 0, width = pixbuf.width, height = pixbuf.height };
		if (!pixbuf.has_alpha || pixbuf.n_channels != 4)
		{
			return box;
		}

		unowned uint8[] pixels = pixbuf.get_pixels_with_length();
		int stride = pixbuf.rowstride;
		int left = pixbuf.width, right = -1, top = pixbuf.height, bottom = -1;
		for (int y = 0; y < pixbuf.height; y++)
		{
			for (int x = 0; x < pixbuf.width; x++)
			{
				if (pixels[y * stride + x * 4 + 3] != 0)
				{
					left = int.min(left, x);
					right = int.max(right, x);
					top = int.min(top, y);
					bottom = int.max(bottom, y);
				}
			}
		}
		if (right >= 0)
		{
			box = Gdk.Rectangle() { x = left, y = top, width = right - left + 1, height = bottom - top + 1 };
		}
		return box;
	}

	// Shows the window on the given output (Wayland only).
	public void show_on_monitor(Gdk.Monitor monitor)
	{
		on_focused_output = false;
		GtkLayerShell.set_monitor(this, monitor);
		place_on(monitor);
		show_animated();
	}

	// Shows the window on the output the compositor picks for a surface that
	// names none, i.e. the focused output (Wayland only).
	public void show_on_focused_output()
	{
		// A shown surface stays on its output: show it afresh, so that it
		// follows a focus change since the last time.
		if (get_mapped())
		{
			hide();
		}
		on_focused_output = true;
		// No output: the compositor picks the focused one.
		Gdk.Monitor? no_monitor = null;
		GtkLayerShell.set_monitor(this, no_monitor);
		show_animated();

		// The output is only known once the surface is on it, so the offsets
		// can only be applied then.
		if (place_timeout_id == 0)
		{
			place_timeout_id = Timeout.add(20, () =>
			{
				var window = get_window();
				if (!on_focused_output || !get_visible() || window == null)
				{
					place_timeout_id = 0;
					return Source.REMOVE;
				}
				var monitor = get_display().get_monitor_at_window(window);
				if (monitor != null)
				{
					place_on(monitor);
				}
				return Source.CONTINUE;
			});
		}
	}

	private void place_on(Gdk.Monitor monitor)
	{
		var margin_top = (int) Math.lround((monitor.workarea.height - _height) * y_offset);
		var margin_left = (int) Math.lround((monitor.workarea.width - _width) * x_offset);
		if (GtkLayerShell.get_margin(this, GtkLayerShell.Edge.TOP) != margin_top)
		{
			GtkLayerShell.set_margin(this, GtkLayerShell.Edge.TOP, margin_top);
		}
		if (GtkLayerShell.get_margin(this, GtkLayerShell.Edge.LEFT) != margin_left)
		{
			GtkLayerShell.set_margin(this, GtkLayerShell.Edge.LEFT, margin_left);
		}
	}

	// Shows the window at the given position on the screen (X11 only).
	public void show_at(int x, int y)
	{
		move(x, y);
		update_shape();
		show_animated();
		raise_window();
	}

	// Puts the shown window above every other window (X11 only): no window
	// manager keeps an unmanaged window on top.
	public void raise_window()
	{
		var window = get_window();
		if (window != null && get_mapped())
		{
			window.raise();
		}
	}

	// Without a transparent visual (on X11 with no compositor) the corners
	// outside the rounded outline cannot be drawn transparent: cut them off the
	// window instead, so that whatever lies beneath shows through.
	private void update_shape()
	{
		if (has_alpha)
		{
			return;
		}

		if (border_radius <= 0)
		{
			shape_combine_region(null);
			return;
		}

		var mask = new Cairo.ImageSurface(Cairo.Format.A1, _width, _height);
		var ctx = new Cairo.Context(mask);
		ctx.set_antialias(Cairo.Antialias.NONE);
		draw_round_rect(ctx, 0, 0, _width, _height, border_radius);
		shape_combine_region(Gdk.cairo_region_create_from_surface(mask));
	}

	public void show_animated()
	{
		remove_tick_callback(prev_callback_id);
		is_fade_in = true;
		prev_callback_id = add_tick_callback(animation_tick);
		show();

		// The notification never takes pointer input, so that it passes to the
		// window beneath it. Showing the window resets its input shape, so set
		// it afresh every time.
		get_window().input_shape_combine_region(new Cairo.Region(), 0, 0);
	}

	public void hide_animated()
	{
		remove_tick_callback(prev_callback_id);
		is_fade_in = false;
		prev_callback_id = add_tick_callback(animation_tick);
	}

	private bool animation_tick(Gtk.Widget widget, Gdk.FrameClock frame_clock)
	{
		frame_clock.begin_updating();
		int64 animation_us_elapsed;
		if (prev_frame_time == 0)
		{
			animation_us_elapsed = 0;
		}
		else
		{
			animation_us_elapsed = (frame_clock.get_frame_time() - prev_frame_time);
		}

		prev_frame_time = frame_clock.get_frame_time();
		var animation_sec_elapsed = (double)animation_us_elapsed / 1000000;
		//var animation_sec_elapsed = (double)us_elapsed(frame_clock) / 1000000;
		//print("ms elapsed: %lld, sec elapsed: %f, fade in : %f, fade out: %f\n", animation_us_elapsed / 1000, animation_sec_elapsed, fade_in, fade_out);
		if (is_fade_in)
		{
			if (opacity >= 1)
			{
				prev_frame_time = 0;
				frame_clock.end_updating();
				return false;
			}

			opacity += animation_sec_elapsed / fade_in;
			if (opacity > 1)
			{
				opacity = 1;
			}

			widget.set_opacity(opacity);
		}
		else
		{
			if (opacity <= 0)
			{
				hide();
				prev_frame_time = 0;
				frame_clock.end_updating();
				faded_out();
				return false;
			}

			opacity -= animation_sec_elapsed / fade_out;
			if (opacity < 0)
			{
				opacity = 0;
			}

			widget.set_opacity(opacity);
		}

		frame_clock.end_updating();
		return true; // Keep going
	}

	private bool on_draw(Gtk.Widget widget, Cairo.Context ctx)
	{
		double block_width = (_width - 2 * padding - 2 * border_width -
		                      (double) ((block_count - 1) * block_spacing)) / block_count;

		double blocks_x = padding + border_width;
		double blocks_y = _height - padding - border_width - block_height;

		ctx.set_operator(Cairo.Operator.SOURCE);
		ctx.paint();

		ctx.set_operator(Cairo.Operator.CLEAR);
		draw_rect(ctx, 0, 0, _width, _height);

		ctx.set_operator(Cairo.Operator.SOURCE);
		Gdk.cairo_set_source_rgba(ctx, border_color);
		draw_round_rect(ctx, 0, 0, _width, _height, border_radius);

		Gdk.cairo_set_source_rgba(ctx, background);
		draw_round_rect(ctx, border_width, border_width, _width - 2 * border_width, _height - 2 * border_width, int.max(border_radius - border_width, 0));

		Gdk.cairo_set_source_rgba(ctx, bar_bg_color);

		for (int i = 0; i < block_count; i++)
		{
			draw_rect(ctx, blocks_x + (block_width + block_spacing) * i,
			               blocks_y,
			               block_width,
			               block_height);
		}

		Gdk.cairo_set_source_rgba(ctx, bar_fg_color);

		if (block_spacing > 0)
		{
			for (int i = 0; i < (int) (block_count * progress); i++)
			{
				draw_rect(ctx, blocks_x + (block_width + block_spacing) * i,
				               blocks_y,
				               block_width,
				               block_height);
			}
		}
		else
		{
			var width = block_width * block_count * progress;
			var height = block_height;
			draw_rect(ctx, blocks_x,
			               blocks_y,
			               width,
			               height);
		}

		ctx.set_operator(Cairo.Operator.OVER);

		return false;
	}

	private void draw_rect(Cairo.Context ctx, double x, double y, double w, double h)
	{
		ctx.line_to(x, y);
		ctx.line_to(x + w, y);
		ctx.line_to(x + w, y + h);
		ctx.line_to(x, y + h);
		ctx.close_path();
		ctx.fill();
	}

	private void draw_round_rect(Cairo.Context ctx, double x, double y, double w, double h, double r)
	{
		ctx.move_to(x + r, y);
		ctx.line_to(x + w - r, y);

		ctx.arc(x + w - r, y + r, r, -Math.PI / 2, 0);

		ctx.line_to(x + w, y + h - r);

		ctx.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);

		ctx.line_to(x + r, y + h);

		ctx.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);

		ctx.line_to(x, y + r);

		ctx.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);

		ctx.close_path();
		ctx.fill();
	}
}


[DBus (name = "org.danb.avizo.service")]
public class AvizoService : GLib.Object
{
	private static string[] props = {
		"image_opacity", "progress", "width", "height", "padding", "monitor",
		"border_radius", "border_width", "block_height", "block_spacing", "block_count", "fade_in", "fade_out", "background", "border_color",
		"bar_fg_color", "bar_bg_color", "x_offset", "y_offset",
	};

	// Each notification shows the image that was set last: image_path or
	// image_resource. Setting either one passes it on to the windows every
	// time, also when the value is unchanged; a property binding would skip
	// that, and would apply both to a new window in a fixed order.
	private string _image_path = "";
	private string _image_resource = "volume_muted";
	private bool _image_from_path = false;

	public string image_path
	{
		get
		{
			return _image_path;
		}

		set
		{
			_image_path = value;
			_image_from_path = value != "";
			update_window_images();
		}
	}

	public string image_resource
	{
		get
		{
			return _image_resource;
		}

		set
		{
			_image_resource = value;
			if (value != "")
			{
				_image_from_path = false;
			}
			update_window_images();
		}
	}

	public double image_opacity { get; set; default = 1.0; }
	public double progress { get; set; default = 0.0; }
	public int width { get; set; default = 248; }
	public int height { get; set; default = 232; }
	public int padding { get; set; default = 24; }
	public double y_offset { get; set; default = 0.75; }
	public double x_offset { get; set; default = 0.50; }
	public int border_radius { get; set; default = 16; }
	public int border_width { get; set; default = 1; }
	public int block_height { get; set; default = 10; }
	public int block_spacing { get; set; default = 2; }
	public int block_count { get; set; default = 20; }
	public double fade_in { get; set; default = 0.2; }
	public double fade_out { get; set; default = 0.5; }
	public Gdk.RGBA background { get; set; default = rgba(160, 160, 160, 0.8); }
	public Gdk.RGBA border_color { get; set; default = rgba(90, 90, 90, 0.8); }
	public Gdk.RGBA bar_fg_color { get; set; default = rgba(0, 0, 0, 0.8); }
	public Gdk.RGBA bar_bg_color { get; set; default = rgba(106, 106, 106, 0.8); }
	public int monitor { get; set; default = -1; }
	public bool focused_output { get; set; default = false; }

	private Array<AvizoWindow> _windows = new Array<AvizoWindow>();
	// Counts the Show() calls: only the hide timer of the latest one hides the
	// notification, so each call decides how long the notification stays.
	private uint _show_serial = 0;

	// The longest time a notification stays, in seconds: longer times would
	// overflow the timer's milliseconds.
	private const double MAX_SECONDS = 3600;

	// Whether the root window is watched to keep the notifications on top (X11).
	private bool x11_stacking = false;

	private void update_window_images()
	{
		for (uint i = 0; i < _windows.length; i++)
		{
			var window = _windows.index(i);
			if (window != null)
			{
				set_window_image(window);
			}
		}
	}

	private void set_window_image(AvizoWindow window)
	{
		if (_image_from_path)
		{
			window.image_path = _image_path;
		}
		else
		{
			window.image_resource = _image_resource;
		}
	}

	public void show(double seconds) throws DBusError, IOError
	{
		var display = Gdk.Display.get_default();
		var monitors = display.get_n_monitors();

		if (_windows.length < monitors)
		{
			_windows.set_size(monitors);
		}

		if (monitor >= monitors)
		{
			stderr.printf(@"Monitor: $(monitor) does not exist\n");
			return;
		}

		// With no monitor chosen, focused_output shows the notification only on
		// the focused output: one window that the compositor places (Wayland),
		// or the window of the monitor the user is working on (X11).
		var on_focused_output = monitor < 0 && focused_output && is_wayland(display);
		var target = monitor;
		if (on_focused_output)
		{
			target = 0;
		}
		else if (monitor < 0 && focused_output)
		{
			target = x11_focused_monitor(display);
		}

		for (int i = 0; i < monitors; i++)
		{
			if (target == -1 || target == i)
			{
				var window = _windows.index(i);
				if (window == null)
				{
					window = create_window(display);
					set_window(i, window);
				}
				show_window(window, on_focused_output ? null : display.get_monitor(i));
			}
		}

		// Hide what an earlier notification left on other outputs.
		if (target != -1)
		{
			for (int i = 0; i < _windows.length; i++)
			{
				var window = _windows.index(i);
				if (i != target && window != null && window.get_visible())
				{
					window.hide_animated();
				}
			}
		}

		// D-Bus callers can send any double: NaN and negative times hide at
		// once, and times beyond MAX_SECONDS are cut to it.
		if (seconds.is_nan() || seconds < 0)
		{
			seconds = 0;
		}
		else if (seconds > MAX_SECONDS)
		{
			seconds = MAX_SECONDS;
		}

		var serial = ++_show_serial;
		Timeout.add((uint) (seconds * 1000), () =>
		{
			if (serial == _show_serial)
			{
				for (int i = 0; i < _windows.length; i++)
				{
					var window = _windows.index(i);
					if (window != null && window.get_visible())
					{
						window.hide_animated();
					}
				}
			}

			return false;
		});
	}

	private AvizoWindow create_window(Gdk.Display display)
	{
		var window = new AvizoWindow();

		foreach (var prop_name in props)
		{
			bind_property(prop_name, window, prop_name, BindingFlags.DEFAULT | BindingFlags.SYNC_CREATE);
		}
		set_window_image(window);

		if (is_wayland(display))
		{
			GtkLayerShell.init_for_window(window);
			GtkLayerShell.set_layer(window, GtkLayerShell.Layer.OVERLAY);
			GtkLayerShell.set_anchor(window, GtkLayerShell.Edge.TOP, true);
			GtkLayerShell.set_anchor(window, GtkLayerShell.Edge.LEFT, true);
			GtkLayerShell.set_namespace(window, "avizo");
			GtkLayerShell.set_exclusive_zone(window, -1);
#if HAVE_LATEST_GTK_LAYER_SHELL
			GtkLayerShell.set_keyboard_mode(window, GtkLayerShell.KeyboardMode.NONE);
#else
			GtkLayerShell.set_keyboard_interactivity(window, false);
#endif
		}
		else
		{
			// A faded-out notification leaves no window behind (X11): the next
			// one gets a fresh window.
			window.faded_out.connect(on_x11_window_faded_out);

			if (!x11_stacking)
			{
				// Watch other windows being mapped and restacked, to keep the
				// notification above them.
				x11_stacking = true;
				var root = display.get_default_screen().get_root_window();
				root.set_events(root.get_events() | Gdk.EventMask.SUBSTRUCTURE_MASK);
				root.add_filter(on_x11_root_event);
			}
		}

		return window;
	}

	// Puts the window in the slot of the monitor, in place of the one there:
	// inserting would move the windows of the following monitors along.
	private void set_window(uint index, owned AvizoWindow? window)
	{
		_windows.remove_index(index);
		_windows.insert_val(index, (owned) window);
	}

	private void on_x11_window_faded_out(AvizoWindow window)
	{
		for (uint i = 0; i < _windows.length; i++)
		{
			if (_windows.index(i) == window)
			{
				set_window(i, null);
				break;
			}
		}

		// The fade-out ends in the window's own frame callback: destroy it
		// once that has returned.
		Idle.add(() =>
		{
			window.destroy();
			return Source.REMOVE;
		});
	}

	// Shows the window on the monitor, or on the focused output if it is null.
	private void show_window(AvizoWindow window, Gdk.Monitor? monitor)
	{
		if (monitor == null)
		{
			window.show_on_focused_output();
		}
		else if (is_wayland(monitor.get_display()))
		{
			window.show_on_monitor(monitor);
		}
		else
		{
			var workarea = x11_workarea(monitor);
			window.show_at(workarea.x + (int) Math.lround((workarea.width - width) * x_offset),
			               workarea.y + (int) Math.lround((workarea.height - height) * y_offset));
		}

		window.queue_draw();
	}

	private Gdk.FilterReturn on_x11_root_event(Gdk.XEvent xevent, Gdk.Event event)
	{
		X.Event* xev = (X.Event*) xevent;
		X.Window changed;
		switch (xev.type)
		{
			case X.EventType.MapNotify:
				changed = xev.xmap.window;
				break;
			case X.EventType.ConfigureNotify:
				changed = xev.xconfigure.window;
				break;
			case X.EventType.CirculateNotify:
				changed = xev.xcirculate.window;
				break;
			default:
				return Gdk.FilterReturn.CONTINUE;
		}

		// Raising a notification window reports it here too: only react to
		// the windows of other programs.
		var display = (Gdk.X11.Display) Gdk.Display.get_default();
		if (Gdk.X11.Window.lookup_for_display(display, changed) == null)
		{
			for (int i = 0; i < _windows.length; i++)
			{
				var window = _windows.index(i);
				if (window != null && window.get_visible())
				{
					window.raise_window();
				}
			}
		}

		return Gdk.FilterReturn.CONTINUE;
	}
}

// The area of the monitor that panels and docks leave free (X11): the monitor
// less what the work area of the current desktop, as announced by the window
// manager, leaves out.
Gdk.Rectangle x11_workarea(Gdk.Monitor monitor)
{
	var area = monitor.get_geometry();
	var display = monitor.get_display();
	var workareas = get_x11_root_property(display, "_NET_WORKAREA");
	var desktop = get_x11_root_property(display, "_NET_CURRENT_DESKTOP");
	var i = desktop.length > 0 ? desktop[0] * 4 : 0;
	if (i >= 0 && i + 4 <= workareas.length)
	{
		// The property counts device pixels, the monitor geometry does not.
		var scale = int.max(monitor.get_scale_factor(), 1);
		var desktop_area = Gdk.Rectangle()
		{
			x = (int) workareas[i] / scale,
			y = (int) workareas[i + 1] / scale,
			width = (int) workareas[i + 2] / scale,
			height = (int) workareas[i + 3] / scale
		};
		Gdk.Rectangle free_area;
		if (area.intersect(desktop_area, out free_area))
		{
			area = free_area;
		}
	}
	return area;
}

// The index of the monitor the user is working on (X11): the one holding the
// middle of the active window, or with no active window the one under the
// pointer.
int x11_focused_monitor(Gdk.Display display)
{
	Gdk.Monitor? focused = null;
	var active = get_x11_root_property(display, "_NET_ACTIVE_WINDOW");
	if (active.length > 0 && active[0] != 0)
	{
		var x11_display = (Gdk.X11.Display) display;
		unowned X.Display xdisplay = x11_display.get_xdisplay();
		var window = (X.Window) active[0];
		X.WindowAttributes attributes;
		int x, y;
		X.Window child;
		x11_display.error_trap_push();
		xdisplay.get_window_attributes(window, out attributes);
		var translated = xdisplay.translate_coordinates(window, xdisplay.default_root_window(),
			0, 0, out x, out y, out child);
		if (x11_display.error_trap_pop() == 0 && translated)
		{
			var scale = int.max(display.get_monitor(0).get_scale_factor(), 1);
			focused = display.get_monitor_at_point((x + attributes.width / 2) / scale,
			                                       (y + attributes.height / 2) / scale);
		}
	}

	if (focused == null)
	{
		int x, y;
		display.get_default_seat().get_pointer().get_position(null, out x, out y);
		focused = display.get_monitor_at_point(x, y);
	}

	for (int i = 0; i < display.get_n_monitors(); i++)
	{
		if (display.get_monitor(i) == focused)
		{
			return i;
		}
	}
	return 0;
}

// The values of a 32-bit property of the X11 root window; none if it is not
// set.
long[] get_x11_root_property(Gdk.Display display, string name)
{
	long[] values = {};
	if (!(display is Gdk.X11.Display))
	{
		return values;
	}

	var x11_display = (Gdk.X11.Display) display;
	unowned X.Display xdisplay = x11_display.get_xdisplay();
	var atom = Gdk.X11.get_xatom_by_name_for_display(x11_display, name);
	X.Atom type;
	int format;
	ulong n_items, bytes_after;
	void* data = null;

	x11_display.error_trap_push();
	var status = xdisplay.get_window_property(xdisplay.default_root_window(), atom, 0, 1024,
		false, (X.Atom) X.ANY_PROPERTY_TYPE, out type, out format, out n_items, out bytes_after,
		out data);
	x11_display.error_trap_pop_ignored();

	if (status == X.Success && data != null)
	{
		if (format == 32)
		{
			// Xlib hands 32-bit items over as longs.
			long* items = (long*) data;
			for (ulong i = 0; i < n_items; i++)
			{
				values += items[i];
			}
		}
		X.free(data);
	}
	return values;
}

bool is_wayland(Gdk.Display? display)
{
	return display != null && display.get_type().is_a(get_wayland_type());
}

Gdk.RGBA rgba(int red, int green, int blue, double alpha)
{
	var o = Gdk.RGBA();
	o.red = red / 255.0;
	o.green = green / 255.0;
	o.blue = blue / 255.0;
	o.alpha = alpha;
	return o;
}

void on_bus_acquired(DBusConnection conn)
{
	try
	{
		conn.register_object("/org/danb/avizo/service", new AvizoService());
	}
	catch (IOError e)
	{
		stderr.printf("Could not register service\n");
	}
}

public void main(string[] args)
{
	Gtk.init(ref args);

	Bus.own_name(BusType.SESSION, "org.danb.avizo.service", BusNameOwnerFlags.NONE,
	             on_bus_acquired,
	             () => {},
	             () =>
	             {
	                 // Another instance owns the name (or the bus went away).
	                 stderr.printf("Could not acquire name\n");
	                 Process.exit(1);
	             });

	new AvizoService();

	Gtk.main();
}
