// Generalized version of agent_element.cpp: same ClassFileLoadHook/RetransformClasses
// live-redefine technique, but the target class and the patched-classfile path are read from
// Agent_OnAttach's `options` string instead of being hardcoded at compile time. This lets one
// build serve every round of every bug, driven by patch_manifest.json (see ROUND_DEX_MAP.md).
//
// Attach with: cmd activity attach-agent <pid> <path-to-so>=class=<slash/separated/Name>,file=<abs-path-to-patched-.class>
// (options format matches how the shell command splits `<path>=<options>` on the first '=';
// everything after that is passed through to Agent_OnAttach verbatim, so our own key=value pairs
// can use '=' freely.)
#include <jvmti.h>
#include <android/log.h>
#include <string.h>
#include <stdlib.h>
#include <jni.h>
#include <string>

#define LOGI(...) ((void)__android_log_print(ANDROID_LOG_INFO, "Agent", __VA_ARGS__))
#define LOGE(...) ((void)__android_log_print(ANDROID_LOG_ERROR, "Agent", __VA_ARGS__))

static std::string g_class_name;   // slash-separated internal name, e.g. org/foo/Bar
static std::string g_file_path;    // absolute path to the replacement .class, readable by the app

void JNICALL ClassFileLoadHook(jvmtiEnv *jvmti_env, JNIEnv* jni_env, jclass class_being_redefined, jobject loader, const char* name, jobject protection_domain,
            jint class_data_len, const unsigned char* class_data, jint* new_class_data_len, unsigned char** new_class_data);

static void parseOptions(const char* options) {
    if (options == nullptr) {
        return;
    }
    std::string opts(options);
    size_t pos = 0;
    while (pos < opts.size()) {
        size_t comma = opts.find(',', pos);
        std::string token = opts.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
        size_t eq = token.find('=');
        if (eq != std::string::npos) {
            std::string key = token.substr(0, eq);
            std::string value = token.substr(eq + 1);
            if (key == "class") {
                g_class_name = value;
            } else if (key == "file") {
                g_file_path = value;
            }
        }
        if (comma == std::string::npos) {
            break;
        }
        pos = comma + 1;
    }
}

JNIEXPORT jint JNICALL Agent_OnAttach(JavaVM* vm, char* options, void* reserved){
    LOGI("[Agent] Agent OnAttach, options: %s", options ? options : "(null)");
    parseOptions(options);
    if (g_class_name.empty() || g_file_path.empty()) {
        LOGE("[Agent] missing required options: need class=<slash/Name>,file=<path>");
        return JNI_ERR;
    }
    LOGI("[Agent] target class: %s", g_class_name.c_str());
    LOGI("[Agent] replacement file: %s", g_file_path.c_str());

    jvmtiError err;
    jvmtiEnv *jvmti;
    vm->GetEnv(reinterpret_cast<void**>(&jvmti), JVMTI_VERSION_1_2);
    LOGI("[Agent] got environment, adding capability");

    jvmtiCapabilities capabilities;
    err = jvmti->GetPotentialCapabilities(&capabilities);
    err = jvmti->AddCapabilities(&capabilities);
    LOGI("[Agent] added capability, registering callback");

    jvmtiEventCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.ClassFileLoadHook = &ClassFileLoadHook;
    jvmti->SetEventCallbacks(&callbacks, sizeof(callbacks));
    jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_CLASS_FILE_LOAD_HOOK, NULL);
    LOGI("[Agent] class file load hook enabled");

    jclass* classes; jint class_count;
    unsigned int found = 0;
    err = jvmti->GetLoadedClasses(&class_count, &classes);
    LOGI("[Agent] got %d loaded classes", class_count);

    jclass* clazz = classes;
    std::string signature_wanted = "L" + g_class_name + ";";
    char* signature = nullptr;
    for (int i = 0; i < class_count; i++) {
        err = jvmti->GetClassSignature(classes[i], &signature, NULL);
        if (signature != nullptr && signature_wanted == signature) {
            found = 1;
            clazz = classes + i;
            jvmti->Deallocate((unsigned char*)signature);
            break;
        }
        if (signature != nullptr) {
            jvmti->Deallocate((unsigned char*)signature);
        }
    }
    if (found == 0) {
        LOGE("[Agent] class not found: %s", signature_wanted.c_str());
        return JNI_ERR;
    }

    err = jvmti->RetransformClasses(1, clazz);
    LOGI("[Agent] RetransformClasses returned %d", err);
    if (err != JVMTI_ERROR_NONE) {
        LOGE("[Agent] retransform class error %d", err);
    }

    jvmti->SetEventCallbacks(NULL, sizeof(callbacks));
    LOGI("[Agent] removed callback, onAttach returning");

    return JNI_OK;
}

void JNICALL ClassFileLoadHook(jvmtiEnv *jvmti_env, JNIEnv* jni_env, jclass class_being_redefined, jobject loader, const char* name, jobject protection_domain,
            jint class_data_len, const unsigned char* class_data, jint* new_class_data_len, unsigned char** new_class_data){

    if (name == nullptr || g_class_name != name) {
        return;
    }
    LOGI("[Agent] ClassFileLoadHook: %s (original class_data_len=%d)", name, class_data_len);

    jstring file_path = jni_env->NewStringUTF(g_file_path.c_str());
    jclass file_class = jni_env->FindClass("java/io/File");
    jmethodID file_constructor = jni_env->GetMethodID(file_class, "<init>", "(Ljava/lang/String;)V");
    jobject file_object = jni_env->NewObject(file_class, file_constructor, file_path);
    jmethodID file_length = jni_env->GetMethodID(file_class, "length", "()J");
    jlong file_size = jni_env->CallLongMethod(file_object, file_length);

    if (file_size <= 0) {
        LOGE("[Agent] replacement file missing or empty: %s", g_file_path.c_str());
        jni_env->DeleteLocalRef(file_path);
        jni_env->DeleteLocalRef(file_class);
        jni_env->DeleteLocalRef(file_object);
        return;
    }

    jvmtiError err = jvmti_env->Allocate(file_size, (unsigned char**)new_class_data);
    if (err != JVMTI_ERROR_NONE) {
        LOGE("[Agent] Error allocating memory for modified bytecode");
        jni_env->DeleteLocalRef(file_path);
        jni_env->DeleteLocalRef(file_class);
        jni_env->DeleteLocalRef(file_object);
        return;
    }

    jclass file_input_stream_class = jni_env->FindClass("java/io/FileInputStream");
    jmethodID file_input_stream_constructor = jni_env->GetMethodID(file_input_stream_class, "<init>", "(Ljava/io/File;)V");
    jobject file_input_stream_object = jni_env->NewObject(file_input_stream_class, file_input_stream_constructor, file_object);

    jmethodID read_method = jni_env->GetMethodID(file_input_stream_class, "read", "([B)I");
    jbyteArray byte_array = jni_env->NewByteArray(file_size);
    jni_env->CallIntMethod(file_input_stream_object, read_method, byte_array);

    jni_env->GetByteArrayRegion(byte_array, 0, file_size, (jbyte*)*new_class_data);
    *new_class_data_len = file_size;

    jni_env->DeleteLocalRef(file_path);
    jni_env->DeleteLocalRef(file_class);
    jni_env->DeleteLocalRef(file_object);
    jni_env->DeleteLocalRef(file_input_stream_class);
    jni_env->DeleteLocalRef(file_input_stream_object);
    jni_env->DeleteLocalRef(byte_array);

    LOGI("[Agent] ClassFileLoadHook returning %d bytes", *new_class_data_len);
}
