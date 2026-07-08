 #include <jvmti.h>
#include <android/log.h>
#include <string.h>
#define LOGI(...) ((void)__android_log_print(ANDROID_LOG_INFO, "Agent", __VA_ARGS__))
#define LOGE(...) ((void)__android_log_print(ANDROID_LOG_ERROR, "Agent", __VA_ARGS__))
#define TYPE_INT 1
#define TYPE_DBL 2
#define TYPE_OBJ 3
#define TYPE_STR 4

JNIEXPORT void JNICALL
ClassFileLoadHook(jvmtiEnv *jvmti_env,
            JNIEnv* jni_env,
            jclass class_being_redefined,
            jobject loader,
            const char* name,
            jobject protection_domain,
            jint class_data_len,
            const unsigned char* class_data,
            jint* new_class_data_len,
            unsigned char** new_class_data) 
{
            jvmtiError err = JVMTI_ERROR_NONE;

            LOGI("[Agent] %s", name);
            *new_class_data_len = class_data_len;
            *new_class_data = (unsigned char *) class_data;

}

void breakpointCallback(jvmtiEnv *jvmti_env, JNIEnv* jni_env,
     jthread thread, jmethodID method, jlocation location) ;

jvmtiError set_breakpoint(jvmtiEnv *jvmti, const char* class_signature, const char* method_inst, const char* method_inst_signature, jlocation bci){
    // find methodID of the function
    jclass* classes; jint class_count;
    unsigned int found = 0; jvmtiError err = JVMTI_ERROR_NONE;
    err = jvmti->GetLoadedClasses(&class_count, &classes);
    LOGI("[Agent] loaded classes");

    jmethodID* methods; jint method_count;
    for (int i = 0; i < class_count; i++) {
        char* signature; 
        err = jvmti->GetClassSignature(classes[i], &signature, NULL);
        
        if (strcmp(signature, class_signature) == 0) {
            // Found the class, now get its methods
            LOGI("[Agent] found class: %s",  class_signature);
            found = 1;
            err = jvmti->GetClassMethods(classes[i], &method_count, &methods);
            break;
        }
        jvmti->Deallocate((unsigned char*)signature);
    }
    if(found == 0){
        LOGE("[Agent] class not found: %s", class_signature);
        return JVMTI_ERROR_ABSENT_INFORMATION;
    }
    found = 0;
    jmethodID method = NULL;
    for (int j = 0; j < method_count; j++) {
        err = JVMTI_ERROR_NONE;
        char* method_name; char* method_signature;
        err = jvmti->GetMethodName(methods[j], &method_name, &method_signature, NULL);
        if(strcmp(method_name, method_inst)==0){
            if(method_inst_signature==NULL || strcmp(method_inst_signature, method_signature)==0){
                err = jvmti->SetBreakpoint(methods[j], bci);
                LOGI("[Agent] set breakpoint: %s", method_name);
                LOGI("[Agent] signature: %s", method_signature);
                found = 1;
                if(method_inst_signature!=NULL){
                    break;
                }
            }
        }
        jvmti->Deallocate((unsigned char*)method_name);
        jvmti->Deallocate((unsigned char*)method_signature);
    }
    if(err != JVMTI_ERROR_NONE){
        LOGE("[Agent] set breakpoint error %d", err);
    }
    if(found == 0){
        LOGE("[Agent] method not found: %s", method_inst);
        return JVMTI_ERROR_ABSENT_INFORMATION;
    }
    return err;
}

jvmtiError print_stacktrace(jvmtiEnv *jvmti, jthread thread, jint num_frames){
    jvmtiError err = JVMTI_ERROR_NONE;

    jvmtiFrameInfo frames[num_frames]; jint frame_count;
    err = jvmti->GetStackTrace(thread, 0, num_frames, frames, &frame_count);
    if (err != JVMTI_ERROR_NONE || frame_count < 1){
        LOGE("[Agent] error getting stack trace");
        return err;
    }
    char *methodName; char *signature;
    LOGI("[Agent] start stack trace");
    for (int i = 0; i < frame_count; i++) {
        err = jvmti->GetMethodName(frames[i].method, &methodName, &signature, NULL);
        LOGI("%s, signature: %s", methodName, signature);
    }
    LOGI("[Agent] end stack trace");
    return err;
}

jvmtiError print_variable(jvmtiEnv *jvmti, JNIEnv* jni_env, jthread thread, jmethodID method, const char* variable_name, unsigned int type){
    jvmtiError err = JVMTI_ERROR_NONE;

    jint var_count; jvmtiLocalVariableEntry* variables;
    err = jvmti->GetLocalVariableTable(method, &var_count, &variables);
    if(err != JVMTI_ERROR_NONE){
        LOGE("[Agent] Error getting local variable table");
        return err;
    }

    jint var_slot; unsigned int found = 0;
    for (int i = 0; i < var_count; i++) {
        if(strcmp(variables[i].name, variable_name)==0){
            var_slot = variables[i].slot; found = 1;
            break;
        }
    }
    if(found == 0){
        LOGE("[Agent] variable %s not found", variable_name);
        return JVMTI_ERROR_ABSENT_INFORMATION;
    }
    if(type == TYPE_INT){
        jint value;
        err = jvmti->GetLocalInt(thread, 0, var_slot, &value);
        LOGI("[Agent] %s = %d", variable_name, value);
    }
    else if(type == TYPE_OBJ){
        jobject obj;
        jvmti->GetLocalObject(thread, 0, var_slot, &obj);
        if(err != JVMTI_ERROR_NONE || obj == NULL){
            LOGE("[Agent] error getting object: %s", variable_name);
            return err;
        }
        jclass clazz = jni_env->GetObjectClass(obj);
        if (clazz == NULL) {
            LOGE("[Agent] Failed to find class for var %s", variable_name);
            return err; 
        }
        jmethodID hashCode_method = jni_env->GetMethodID(clazz, "hashCode", "()I");
        if (hashCode_method == NULL) {
            LOGE("[Agent] Failed to find toString method for var %s", variable_name);
            return err; 
        }
        jint hashcode = jni_env->CallIntMethod(obj, hashCode_method);
        printf("[Agent] %s = %d", variable_name, hashcode);
    }
    else if(type == TYPE_STR){
        jobject obj;
        jvmti->GetLocalObject(thread, 0, var_slot, &obj);
        if(err != JVMTI_ERROR_NONE || obj == NULL){
            LOGE("[Agent] error getting object: %s", variable_name);
            return err;
        }
        jclass clazz = jni_env->GetObjectClass(obj);
        if (clazz == NULL) {
            LOGE("[Agent] Failed to find class for var %s", variable_name);
            return err; 
        }
        jmethodID toString_method = jni_env->GetMethodID(clazz,"toString", "()Ljava/lang/String;");
        if (toString_method == NULL) {
            LOGE("[Agent] Failed to find toString method for var %s", variable_name);
            return err; 
        }
        jstring str = (jstring) jni_env->CallObjectMethod(obj, toString_method);
        const char* cstr = jni_env->GetStringUTFChars(str, NULL);
        printf("[Agent] %s = %s", variable_name, cstr);
    }
    return err;
}

jvmtiError print_all_signatures(jvmtiEnv *jvmti, const char* class_signature){
    // find methodID of the function
    jclass* classes; jint class_count;
    unsigned int found = 0; jvmtiError err = JVMTI_ERROR_NONE;
    err = jvmti->GetLoadedClasses(&class_count, &classes);
    LOGI("[Agent] loaded classes");

    jmethodID* methods; jint method_count;
    for (int i = 0; i < class_count; i++) {
        char* signature; 
        err = jvmti->GetClassSignature(classes[i], &signature, NULL);
        
        if (strcmp(signature, class_signature) == 0) {
            // Found the class, now get its methods
            LOGI("[Agent] found class: %s",  class_signature);
            found = 1;
            err = jvmti->GetClassMethods(classes[i], &method_count, &methods);
            break;
        }
        jvmti->Deallocate((unsigned char*)signature);
    }
    if(found == 0){
        LOGE("[Agent] class not found: %s", class_signature);
        return JVMTI_ERROR_ABSENT_INFORMATION;
    }

    jmethodID method = NULL;
    for (int j = 0; j < method_count; j++) {
        err = JVMTI_ERROR_NONE;
        char* method_name; char* method_signature;
        err = jvmti->GetMethodName(methods[j], &method_name, &method_signature, NULL);
        LOGI("[Agent] function: %s", method_name);
        LOGI("[Agent] %s signature: %s", method_name, method_signature);
        jvmti->Deallocate((unsigned char*)method_name);
        jvmti->Deallocate((unsigned char*)method_signature);
    }
   
    return err;
}

JNIEXPORT jint JNICALL Agent_OnAttach(JavaVM* vm, char* options, void* reserved){
    LOGI("[Agent] Agent OnAttach");
    jvmtiError err;
    // get jvmti environment
    jvmtiEnv *jvmti;
    vm->GetEnv(reinterpret_cast<void**>(&jvmti), JVMTI_VERSION_1_2);
    LOGI("[Agent] got environment, adding capability");

    jvmtiCapabilities capabilities; 
    err = jvmti->GetPotentialCapabilities(&capabilities);
    LOGI("[Agent] got capabilities");
    // beter practice to not add all capabilities later 
    err = jvmti->AddCapabilities(&capabilities);
    LOGI("[Agent] added capability, registering callback");

    jvmtiEventCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.Breakpoint = &breakpointCallback; // &breakpointCallback is function pointer
    jvmti->SetEventCallbacks(&callbacks, sizeof(callbacks));
    LOGI("[Agent] callback registered, enabling break point");

    jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_BREAKPOINT, NULL);
    // thread is NULL, should enable globally
    LOGI("[Agent] enabled, setting break point");

    ///////////////////////////////////////////////////////////////

    err = set_breakpoint(jvmti, "Lorg/matrix/android/sdk/internal/session/room/send/DefaultSendService;", "sendTextMessage", "(Ljava/lang/CharSequence;Ljava/lang/String;ZLjava/util/Map;)Lorg/matrix/android/sdk/api/util/Cancelable;", 0);
    err = set_breakpoint(jvmti, "Lorg/matrix/android/sdk/internal/session/room/send/LocalEchoEventFactory;", "createEvent", NULL, 0);
    err = set_breakpoint(jvmti, "Lorg/matrix/android/sdk/internal/session/room/send/DefaultSendService;", "createLocalEcho", NULL, 0);
    err = set_breakpoint(jvmti, "Lorg/matrix/android/sdk/internal/session/room/send/DefaultSendService;", "sendEvent", "(Lorg/matrix/android/sdk/api/session/events/model/Event;)Lorg/matrix/android/sdk/api/util/Cancelable;", 0);

    if(err != JVMTI_ERROR_NONE){
        LOGE("[Agent] set breakpoint error %d", err);
    }
    LOGI("[Agent] returning");

    return JNI_OK;
}

void breakpointCallback(jvmtiEnv *jvmti_env, JNIEnv* jni_env,
    jthread thread, jmethodID method, jlocation location) {
    jvmtiError err;
    char* method_name; char* method_signature;
    err = jvmti_env->GetMethodName(method, &method_name, &method_signature, NULL);

    if(strcmp(method_name, "sendTextMessage")==0 && strcmp(method_signature, "(Ljava/lang/CharSequence;Ljava/lang/String;ZLjava/util/Map;)Lorg/matrix/android/sdk/api/util/Cancelable;")==0 && location == 0){
    
        LOGI("[Agent][method] %s", method_name);
        LOGI("[Agent][signature] %s", method_signature);

        LOGI("[Agent] ID=%d", 0);
        err = print_variable(jvmti_env, jni_env, thread, method, "text", TYPE_INT);
    }
    if(strcmp(method_name, "createEvent")==0 && location == 0){
    
        LOGI("[Agent][method] %s", method_name);
        LOGI("[Agent][signature] %s", method_signature);

        LOGI("[Agent] ID=%d", 1);
    }
    if(strcmp(method_name, "createLocalEcho")==0 && location == 0){
    
        LOGI("[Agent][method] %s", method_name);
        LOGI("[Agent][signature] %s", method_signature);

        LOGI("[Agent] ID=%d", 2);
    }
    if(strcmp(method_name, "sendEvent")==0 && strcmp(method_signature, "(Lorg/matrix/android/sdk/api/session/events/model/Event;)Lorg/matrix/android/sdk/api/util/Cancelable;")==0 && location == 0){
    
        LOGI("[Agent][method] %s", method_name);
        LOGI("[Agent][signature] %s", method_signature);

        LOGI("[Agent] ID=%d", 3);
    }

}
