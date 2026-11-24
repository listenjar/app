#include "my_application.h"

#include <errno.h>
#include <flutter_linux/flutter_linux.h>
#include <string.h>

#include "flutter/generated_plugin_registrant.h"

// One ListenJar window per build. The sign-in page in the browser opens
// <kUrlScheme>://sign-in (appScheme in lib/config.dart); the process the
// desktop starts for it activates the running instance over D-Bus, which
// presents its window, and exits. A <kUrlScheme>://open?url=… link, or a
// link as the argument, goes on to the running instance's Dart side
// (lib/shared_links.dart) the same way. Debug builds use their own scheme and
// application ID, so a dev build and an installed release don't take each
// other's links or windows.
#ifdef NDEBUG
static constexpr char kUrlScheme[] = "listenjar";
static constexpr char kApplicationId[] = APPLICATION_ID;
#else
static constexpr char kUrlScheme[] = "listenjar-dev";
static constexpr char kApplicationId[] = APPLICATION_ID ".dev";
#endif

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // lib/shared_links.dart: links for Dart, held until it asks for them.
  FlMethodChannel* links;
  GPtrArray* pending_links;
  gboolean links_ready;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Hands a shared link to Dart, or holds it until Dart is listening.
static void send_link(MyApplication* self, const gchar* link) {
  if (self->links_ready && self->links != nullptr) {
    g_autoptr(FlValue) argument = fl_value_new_string(link);
    fl_method_channel_invoke_method(self->links, "open", argument, nullptr,
                                    nullptr, nullptr);
    return;
  }
  g_ptr_array_add(self->pending_links, g_strdup(link));
}

// Dart asks for the links that came before it listened ("pending").
static void links_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                          gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(fl_method_call_get_name(call), "pending") == 0) {
    g_autoptr(FlValue) list = fl_value_new_list();
    for (guint i = 0; i < self->pending_links->len; i++) {
      fl_value_append_take(
          list, fl_value_new_string(static_cast<const gchar*>(
                    g_ptr_array_index(self->pending_links, i))));
    }
    g_ptr_array_set_size(self->pending_links, 0);
    self->links_ready = TRUE;
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(list));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // Activated again, say by the sign-in page's link: present the window.
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows != nullptr) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_default_size(window, 1280, 720);
  // Narrower than this, lib/main.dart's top bar and feed rows overflow.
  gtk_widget_set_size_request(GTK_WIDGET(window), 520, 400);

  // If you want to use a header bar, uncomment the following lines.
  // Header bars are commonly used in GNOME based desktop environments and
  // allow additional widgets to be added to the title bar.
  // See https://docs.gtk.org/gtk3/class.HeaderBar.html
  // GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
  // gtk_widget_show(GTK_WIDGET(header_bar));
  // gtk_header_bar_set_show_close_button(header_bar, TRUE);
  // gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));

  gtk_window_set_title(window, "ListenJar");

  // The icon CMake installed next to the executable, in data/.
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable != nullptr) {
    g_autofree gchar* directory = g_path_get_dirname(executable);
    g_autofree gchar* icon =
        g_build_filename(directory, "data", "app_icon.png", nullptr);
    gtk_window_set_icon_from_file(window, icon, nullptr);
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#f5f4f0");  // paper (DESIGN.md)
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->links = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "listenjar/links", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->links, links_call_cb, self,
                                            nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  // Opened again with links (`listenjar <link>`, or a <kUrlScheme>://open
  // link): hand them to the running instance, which opens them. A first
  // launch gives them to Dart as arguments instead (lib/main.dart).
  gchar** links = *arguments + 1;
  if (g_application_get_is_remote(application) && links[0] != nullptr) {
    guint count = g_strv_length(links);
    GFile** files = g_new(GFile*, count);
    for (guint i = 0; i < count; i++) {
      files[i] = g_file_new_for_commandline_arg(links[i]);
    }
    g_application_open(application, files, count, "");
    for (guint i = 0; i < count; i++) {
      g_object_unref(files[i]);
    }
    g_free(files);
  } else {
    g_application_activate(application);
  }
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::open: links from another launch, in the running
// instance. Presents the window and hands them to Dart.
static void my_application_open(GApplication* application, GFile** files,
                                gint count, const gchar* hint) {
  MyApplication* self = MY_APPLICATION(application);
  my_application_activate(application);
  for (gint i = 0; i < count; i++) {
    g_autofree gchar* uri = g_file_get_uri(files[i]);
    send_link(self, uri);
  }
}

// Points kUrlScheme at this executable for the current user: a hidden
// .desktop file in ~/.local/share/applications and the x-scheme-handler
// default, so the link works however the app was installed.
static void register_url_scheme() {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  // Desktop entry Exec quoting would need these escaped twice; skip instead.
  if (exe == nullptr || strpbrk(exe, "\"`$\\\n") != nullptr) {
    return;
  }
  g_autofree gchar* name = g_strdup_printf("%s.desktop", kApplicationId);
  g_autofree gchar* dir =
      g_build_filename(g_get_user_data_dir(), "applications", nullptr);
  g_autofree gchar* path = g_build_filename(dir, name, nullptr);
  g_autofree gchar* entry = g_strdup_printf(
      "[Desktop Entry]\n"
      "Type=Application\n"
      "Name=ListenJar\n"
      "Exec=\"%s\" %%u\n"
      "NoDisplay=true\n"
      "MimeType=x-scheme-handler/%s;\n",
      exe, kUrlScheme);
  g_autoptr(GError) error = nullptr;
  if (g_mkdir_with_parents(dir, 0700) != 0 ||
      !g_file_set_contents(path, entry, -1, &error)) {
    g_warning("Failed to register %s://: %s", kUrlScheme,
              error != nullptr ? error->message : g_strerror(errno));
    return;
  }
  g_autofree gchar* mime = g_strdup_printf("x-scheme-handler/%s", kUrlScheme);
  const gchar* argv[] = {"xdg-mime", "default", name, mime, nullptr};
  if (!g_spawn_async(nullptr, const_cast<gchar**>(argv), nullptr,
                     G_SPAWN_SEARCH_PATH, nullptr, nullptr, nullptr, &error)) {
    g_warning("Failed to register %s://: %s", kUrlScheme, error->message);
  }
}

// Implements GApplication::startup: runs in the primary instance only.
static void my_application_startup(GApplication* application) {
  register_url_scheme();

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->links);
  g_clear_pointer(&self->pending_links, g_ptr_array_unref);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->pending_links = g_ptr_array_new_with_free_func(g_free);
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(kApplicationId);
  // What GTK and the desktop show as the app's name, which would otherwise
  // fall back to the application ID.
  g_set_application_name("ListenJar");

  // Unique: a second launch activates the first instance and exits.
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", kApplicationId, "flags",
                                     G_APPLICATION_HANDLES_OPEN, nullptr));
}
