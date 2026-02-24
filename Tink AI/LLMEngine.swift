import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXRandom
import Tokenizers
import Observation

@Observable
class LLMEngine {
    var outputText: String = ""
    var isGenerating: Bool = false
    var isModelLoaded: Bool = false
    var loadProgress: Double = 0.0
    var statusMessage: String = "Initializing..."
    var uploadedFileContent: String = ""
    var uploadedFileName: String = ""
    
    private var modelContainer: ModelContainer?
    
    @MainActor
    func loadModel() async {
        guard !isModelLoaded else { return }
        
        do {
            try await Task.sleep(nanoseconds: 500_000_000)
            loadProgress = 0.3
            statusMessage = "Loading Weights..."
            
            guard let modelPath = Bundle.main.path(forResource: "maths_and_physics", ofType: nil) else {
                statusMessage = "Error: Model not found."
                return
            }
            
            let modelURL = URL(fileURLWithPath: modelPath)
            let configuration = ModelConfiguration(directory: modelURL)
            
            loadProgress = 0.6
            
            // Move heavy loading to background thread to avoid freezing UI
            let container = try await Task.detached {
                try await LLMModelFactory.shared.loadContainer(configuration: configuration)
            }.value
            
            loadProgress = 1.0
            statusMessage = "Ready!"
            
            try await Task.sleep(nanoseconds: 300_000_000)
            self.modelContainer = container
            self.isModelLoaded = true
            
        } catch {
            statusMessage = "Load Error: \(error.localizedDescription)"
        }
    }
    
    func ask(_ question: String) async {
        guard let container = modelContainer else { return }
        
        // Ensure UI state is reset on MainActor before starting
        await MainActor.run {
            self.isGenerating = true
            self.outputText = ""
        }
        
        var systemPrompt = """
        <|im_start|>system
        You are a Math and Physics tutor. Your ONLY job is to provide detailed, step-by-step explanations.
        
        CRITICAL - YOU MUST FOLLOW THIS FORMAT EXACTLY:
        
        **Concept Explanation:**
        [Provide thorough explanation of the concept and theory]
        
        **Step-by-Step Solution:**
        
        Step 1: [First action with explanation]
        [Show work and reasoning]
        
        Step 2: [Second action with explanation]
        [Show work and reasoning]
        
        Step 3: [Continue for all steps needed]
        [Show work and reasoning]
        
        **Final Answer:**
        [State the final answer clearly]
        
        RULES YOU MUST FOLLOW:
        1. ALWAYS break problems into numbered steps (Step 1, Step 2, etc).
        2. NEVER give just the answer - explain EVERYTHING.
        3. Show ALL calculations and intermediate work.
        4. Explain WHY each step is done.
        5. Use math formatting: $$ ... $$ for important equations and $ ... $ for inline math expressions. ALWAYS wrap complete mathematical terms together (e.g., $5x$, not 5 $x$). Include coefficients with variables inside the same $ markers.
        6. If you don't break into steps, you have FAILED.
        7. Every response must be at least 500 words.
        """
        
        // Include file context if available
        if !uploadedFileContent.isEmpty {
            systemPrompt += """
            
            ========== CRITICAL INSTRUCTION - YOU ARE IN FILE MODE ==========
            
            A reference file has been provided BELOW. You MUST follow these rules:
            
            FILE NAME: \(uploadedFileName)
            
            FILE CONTENT:
            --------BEGIN FILE--------
            \(uploadedFileContent)
            --------END FILE--------
            
            MANDATORY RULES FOR FILE MODE - YOU WILL FAIL IF YOU DON'T FOLLOW THESE:
            
            1. YOU MUST ONLY USE INFORMATION FROM THE FILE ABOVE.
            2. YOU MUST NOT GENERATE, INVENT, OR MAKE UP ANY INFORMATION.
            3. YOU MUST NOT HALLUCINATE OR FABRICATE SOLUTIONS.
            4. IF THE PROBLEM IS IN THE FILE, SOLVE IT USING ONLY FILE INFORMATION.
            5. IF INFORMATION IS NOT IN THE FILE, YOU MUST SAY: "This information is not provided in the uploaded file."
            6. QUOTE DIRECTLY FROM THE FILE when citing information.
            7. DO NOT CREATE EXAMPLES THAT ARE NOT IN THE FILE.
            8. DO NOT ADD INFORMATION FROM YOUR TRAINING DATA.
            9. DO NOT SOLVE DIFFERENT PROBLEMS - SOLVE ONLY THE PROBLEM IN THE FILE.
            10. EVERY ANSWER MUST BE TRACEABLE TO THE FILE CONTENT.
            
            YOUR TASK: Solve the problem provided in the file using ONLY the information in that file.
            
            WARNING: Generating information not in the file will result in failure. Stick to file content only.
            ========== END CRITICAL INSTRUCTION ==========
            """
        }
        
        systemPrompt += "\n<|im_end|>"
        
        let prompt = """
        \(systemPrompt)
        <|im_start|>user
        \(question)
        <|im_end|>
        <|im_start|>assistant
        """
        
        do {
            let result = try await container.perform { context in
                let input = try await context.processor.prepare(input: .init(prompt: prompt))
                
                var generateParams = MLXLMCommon.GenerateParameters(maxTokens: 4096)
                
                // Use much lower temperature when file is uploaded to prevent hallucination
                if await !uploadedFileContent.isEmpty {
                    generateParams.temperature = 0.1  // Very low for file mode - strict adherence
                    generateParams.topP = 0.5         // Very restrictive for file mode
                } else {
                    generateParams.temperature = 0.3  // Normal mode
                    generateParams.topP = 0.8
                }
                
                return try MLXLMCommon.generate(input: input, parameters: generateParams, context: context) { tokens in
                    // Decode tokens
                    let decoded = context.tokenizer.decode(tokens: Array(tokens.dropFirst(input.text.tokens.count)))
                    let clean = decoded.replacingOccurrences(of: "<|im_end|>", with: "")
                                     .replacingOccurrences(of: "<|endoftext|>", with: "")
                                     .trimmingCharacters(in: .whitespaces)
                    
                    // Use DispatchQueue for safer MainActor updates to prevent ViewBridge errors
                    DispatchQueue.main.async {
                        self.outputText = clean
                    }
                    return .more
                }
            }
            
            // Final update - ensure complete output
            let finalOutput = result.output.trimmingCharacters(in: .whitespaces)
            await MainActor.run {
                self.outputText = finalOutput.isEmpty ? "Please try asking your question again." : finalOutput
                self.isGenerating = false
            }
            
        } catch {
            await MainActor.run {
                self.outputText = "Error: \(error.localizedDescription)"
                self.isGenerating = false
            }
        }
    }
    
    func setUploadedFile(name: String, content: String) {
        self.uploadedFileName = name
        self.uploadedFileContent = content
    }
    
    func clearUploadedFile() {
        self.uploadedFileName = ""
        self.uploadedFileContent = ""
    }
}
