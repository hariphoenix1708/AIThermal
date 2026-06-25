import re

with open("webroot/index.html", "r") as f:
    content = f.read()

new_exec = """            static async exec(cmd) {
                return new Promise(async (resolve) => {
                    try {
                        let execFunc = null;

                        if (typeof ksu !== 'undefined' && typeof ksu.exec === 'function') execFunc = ksu.exec;
                        else if (typeof window.ksu !== 'undefined' && typeof window.ksu.exec === 'function') execFunc = window.ksu.exec;
                        else if (typeof window.ksuModuleExec === 'function') execFunc = window.ksuModuleExec;
                        else if (typeof window.kernelsu !== 'undefined' && typeof window.kernelsu.exec === 'function') execFunc = window.kernelsu.exec;

                        if (!execFunc) {
                            resolve({ stdout: "", stderr: "KernelSU API not available.", code: -1 });
                            return;
                        }

                        // Try calling it
                        let result;
                        try {
                            // Some older wrappers require args and a callback
                            // ksu.exec(cmd, args, callback) or ksu.exec(cmd, callback)
                            if (execFunc.length >= 2) {
                                // Try callback style first if function signature expects multiple args
                                execFunc(cmd, (res) => {
                                    resolve({
                                        stdout: (res && res.stdout) ? res.stdout.trim() : "",
                                        stderr: (res && res.stderr) ? res.stderr.trim() : "",
                                        code: (res && res.errno !== undefined) ? res.errno : (res && res.code !== undefined ? res.code : 0)
                                    });
                                });
                                return;
                            } else {
                                // Standard promise-based execution
                                result = await execFunc(cmd);
                            }
                        } catch (e) {
                            resolve({ stdout: "", stderr: e.toString(), code: -1 });
                            return;
                        }

                        // Normalize promise result
                        resolve({
                            stdout: (result && result.stdout) ? result.stdout.trim() : "",
                            stderr: (result && result.stderr) ? result.stderr.trim() : "",
                            code: (result && result.errno !== undefined) ? result.errno : (result && result.code !== undefined ? result.code : 0)
                        });

                    } catch (error) {
                        resolve({ stdout: "", stderr: error.toString(), code: -1 });
                    }
                });
            }"""

content = re.sub(r'static async exec\(cmd\) \{.*?\n            \}\n', new_exec + '\n', content, flags=re.DOTALL)

with open("webroot/index.html", "w") as f:
    f.write(content)
