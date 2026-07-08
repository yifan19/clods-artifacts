#!/usr/bin/env python3

import os
import argparse
from pathlib import Path

CC_dir = '/Users/account/Library/Android/sdk/ndk/26.1.10909125/toolchains/llvm/prebuilt/darwin-x86_64/bin'
CFLAGS = '-fPIC -shared -static-libstdc++ -llog'
INCLUDES = '''-I/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home/include \\
           -I/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home/include/darwin \\
		   -I/Users/account/Library/Android/sdk/ndk/26.1.10909125/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include/android'''


header = '''#include <jvmti.h>
#include <android/log.h>
#include <string.h>

#define LOGI(...) ((void)__android_log_print(ANDROID_LOG_INFO, "Agent", __VA_ARGS__))
#define LOGE(...) ((void)__android_log_print(ANDROID_LOG_ERROR, "Agent", __VA_ARGS__))
#define TYPE_INT 1
#define TYPE_DBL 2
#define TYPE_OBJ 3
#define TYPE_STR 4

void breakpointCallback(jvmtiEnv *jvmti_env, JNIEnv* jni_env,
     jthread thread, jmethodID method, jlocation location) ;
'''

set_breakpoint = '''
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
'''

print_stacktrace = '''
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
'''

print_variable = '''
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
'''

print_all_signatures = '''
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
'''

attach_before = '''
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

'''

attach_after = '''
    if(err != JVMTI_ERROR_NONE){
        LOGE("[Agent] set breakpoint error %d", err);
    }
    LOGI("[Agent] returning");

    return JNI_OK;
}
'''

before_callback = '''
void breakpointCallback(jvmtiEnv *jvmti_env, JNIEnv* jni_env,
    jthread thread, jmethodID method, jlocation location) {
    jvmtiError err;
    char* method_name; char* method_signature;
    err = jvmti_env->GetMethodName(method, &method_name, &method_signature, NULL);

'''
after_callback = '''
}
'''

def generate_onAttach(breakpoints):
    attach_code = attach_before
    for breakpoint in breakpoints:
        if not 'method_name' in breakpoint or not breakpoint['method_name']:
            # no function name specified
            on_attach = '    print_all_signatures(jvmti, "' + breakpoint['class_name'] + '");'
        elif 'method_signature' in breakpoint and breakpoint['method_signature']:
            on_attach =  '    err = set_breakpoint(jvmti, "' + breakpoint['class_name'] + '", "' + breakpoint['method_name'] + '", "' + breakpoint['method_signature'] + '", ' + str(breakpoint['bci']) + ');'
        else:
            on_attach =  '    err = set_breakpoint(jvmti, "' + breakpoint['class_name'] + '", "' + breakpoint['method_name'] + '", NULL, ' + str(breakpoint['bci']) + ');'
        attach_code += on_attach + '\n'
    attach_code += attach_after
    return attach_code

def generate_bci_callback(breakpoint):
    if 'method_signature' in breakpoint and breakpoint['method_signature']:
        on_callback = '    if(strcmp(method_name, "' + breakpoint['method_name'] + '")==0 '
        on_callback += '&& strcmp(method_signature, "' + breakpoint['method_signature'] + '")==0 '
        on_callback += '&& location == ' + str(breakpoint['bci']) + "){"
    else:
        on_callback = '    if(strcmp(method_name, "' + breakpoint['method_name'] + '")==0 && location == ' + str(breakpoint['bci']) + "){"
    on_callback += '''
    \n        LOGI("[Agent][method] %s", method_name);
        LOGI("[Agent][signature] %s", method_signature);\n
'''
    if 'id' in breakpoint and breakpoint['id'] :
        on_callback = on_callback + '        LOGI("[Agent] ID=%d", ' + breakpoint['id'] + ');\n'
    if 'num_frames' in breakpoint and breakpoint['num_frames'] > 0:
        on_callback = on_callback + '        err = print_stacktrace(jvmti_env, thread, ' + str(breakpoint['num_frames']) + ');\n'
    if 'variables' in breakpoint and breakpoint['variables'] :
        for var in breakpoint['variables']:
            on_callback = on_callback + '        err = print_variable(jvmti_env, jni_env, thread, method, "' + var["var_name"] + '", ' + var["var_type"] + ');\n'
    
    on_callback += "    }\n" # if end
    return on_callback

def generate_callbacks(breakpoints):
    callback_code = before_callback
    for breakpoint in breakpoints:
        if 'method_name' in breakpoint and breakpoint['method_name']:
            callback_code += generate_bci_callback(breakpoint)
    callback_code += after_callback
    return callback_code

def generate_agent(breakpoints):
    attach_code = generate_onAttach(breakpoints)
    callback_code = generate_callbacks(breakpoints)
    agent = header + set_breakpoint + print_stacktrace + print_variable + print_all_signatures + attach_code + callback_code
    return agent

make_file_after = '''
$(TARGET): $(SRC)
\t$(CC) $(CFLAGS) $(INCLUDES) $(SRC) -o $(TARGET)

clean:
\trm -f $(TARGET) 

.PHONY: clean
'''

def generate_makefile(API_level = 28, agent_name = 'agent.cpp'):
    if not API_level:
        API_level = 28
    make_file = 'CC = ' + CC_dir + '/aarch64-linux-android' + str(API_level) + '-clang++\n'
    make_file += 'CFLAGS = ' + CFLAGS + '\n'
    make_file += 'INCLUDES = ' + INCLUDES + '\n'
    make_file += 'SRC = ' + agent_name + '\n'
    make_file += 'TARGET = ' + 'libagent.so' + '\n'
    make_file += make_file_after
    return make_file

var_types = {'TYPE_INT': 'TYPE_INT',
             'int': 'TYPE_INT',
             'jint': 'TYPE_INT',
             'TYPE_OBJ': 'TYPE_OBJ',
             'obj': 'TYPE_OBJ',
             'jobject': 'TYPE_OBJ',
             'hash': 'TYPE_OBJ',
             'TYPE_STR': 'TYPE_STR',
             'jstring': 'TYPE_STR',
             'string': 'TYPE_STR',
             'str': 'TYPE_STR',
             'text': 'TYPE_STR',}
def complete_block(block):
    if not "class_name" in block or not block["class_name"]:
        raise ValueError("Missing CLASS")
    if not "method_name" in block or not block["method_name"]:
        print("no method specified for " + block["class_name"] + " print all signatures")
        # raise ValueError("Missing METHOD")
        block["method_name"] = None
    if not "bci" in block or not block["bci"]:
        block["bci"] = 0
    if not "num_frames" in block or not block["num_frames"]:
        block["num_frames"] = 0
    if not "variables" in block:
        block["variables"] = []
    return block

def get_breakpoints(in_file):
    breakpoints = []
    with open(in_file, 'r') as file:
        block = {}
        for line in file:
            line, _, _ = line.partition('#') # get rid of comment
            line = line.strip()
            if not line or line.startswith("#"):  # Skip empty lines and comments
                continue
            key, _, value = line.partition(':')
            key = key.strip()
            value = value.strip()
            if key == "POINT":
                if block:  # If there's an existing block, save it before starting a new one
                    block = complete_block(block)
                    breakpoints.append(block)
                    block = {}
                if value:
                    if value.lstrip("-").isdigit():
                        block["id"] = value
                    else:
                        print("id is not int, skipping")
            elif key == "CLASS":
                block["class_name"] = value
            elif key == "METHOD":
                block["method_name"] = value
            elif key == "AT":
                block["bci"] = int(value)
            elif key == "VARS":
                vars = value.split(',') if value else []
                for var in vars:
                    var = var.strip()
                    var_type, _, var_name = var.partition(' ')
                    if not var_name:
                        raise ValueError("Missing var type or name")
                    if not var_type in var_types:
                        raise ValueError("Invalid var type: " + var_type)
                    block.setdefault("variables", []).append({"var_name": var_name, "var_type": var_types[var_type]})
            elif key == "STACK":
                if not value:
                    value = 10
                value = int(value)
                if value < 0:
                    raise ValueError("Invalid stack depth: " + value)
                block["num_frames"] = int(value)
            elif key== "SIGNATURE":
                if not value:
                    raise ValueError("Missing signature")
                block["method_signature"] = value

        if block:  # the last block
            block = complete_block(block)
            breakpoints.append(block)
            block = {}

    return breakpoints

def confirm_overwrite(file):
    message = str(file) + " exits, Overwrite?"
    response = input(f"{message} (y/n): ").strip().lower()
    return response == 'y'
   
def create_agent(args):

    agent_file = make_file = None
    if args.output_dir.exists():
        if args.output_dir.is_dir():
            agent_file = args.output_dir / "agent.cpp"
            if hasattr(args, 'm_provided'):
                make_file = args.output_dir / "Makefile"
        else: # is a file
            print(args.output_dir, "is not a directory")
            return
    else:
        args.output_dir.mkdir(parents=True)
    
    print("agent file:")
    print(agent_file)
    print("\n")
    
    if agent_file and agent_file.exists():
        if args.y:
            print("Overwriting", agent_file)
        else:
            if not confirm_overwrite(agent_file):
                return
    if make_file and make_file.exists():
        if args.y:
            print("Overwriting", make_file)
        else:
            if not confirm_overwrite(make_file):
                return
        
    breakpoints = get_breakpoints(args.input_file)
    agent = generate_agent(breakpoints)
    with open(agent_file, 'w') as f:
        f.write(agent)
    if hasattr(args, 'm_provided'):
        makefile = generate_makefile(API_level = args.make)
        with open(make_file, 'w') as f:
            f.write(makefile)

def main(args):
    if args.cc_dir is not None:
        CC_dir = args.cc_dir
    if args.cflags is not None:
        CFLAGS = args.cflags
    if args.includes is not None:
        INCLUDES = args.includes

    print("\n//////\n")
    
    print("CC_dir: ")
    print(CC_dir)
    print("CFLAGS: ")
    print(CFLAGS)
    print("INCLUDES: ")
    print(INCLUDES)
    create_agent(args)


class CustomAction(argparse.Action):
    def __call__(self, parser, namespace, values, option_string=None):
        setattr(namespace, 'm_provided', True)
        setattr(namespace, self.dest, values)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-i", "--input-file",
        help="path to instrumentation plan",
        type=Path,
        default=Path('./../plan.btm'))
    parser.add_argument(
        "-o", "--output-dir",
        help="directory to create the agent",
        type=Path,
        default=Path("./../agent/"))
    parser.add_argument('-m', '--make',
        help="also create make file, specify API level",
        action=CustomAction,
        type=int,
        nargs='?',
        default=29)
    parser.add_argument('-y', action='store_true',
        help="Overwrite files")
    
    parser.add_argument('--cc-dir',
        help="CC directory",
        type=str,
        default=None)  
    parser.add_argument('--cflags',
        help="CFLAGS",
        type=str,
        default=None)
    parser.add_argument('--includes',
        help="INCLUDES",
        type=str,
        default=None)
    
    args = parser.parse_args()
    print(args)

    main(args)







