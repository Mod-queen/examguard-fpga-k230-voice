"""Scrollable panel body so controls remain reachable on a small dashboard."""
import tkinter as tk
from tkinter import ttk

class PanelViewport(ttk.Frame):
    def __init__(self,parent):
        super().__init__(parent)
        self.pack(fill='both',expand=True)
        self.columnconfigure(0,weight=1);self.rowconfigure(0,weight=1)
        self.canvas=tk.Canvas(self,highlightthickness=0,borderwidth=0)
        self.canvas.grid(row=0,column=0,sticky='nsew')
        self.vertical=ttk.Scrollbar(self,orient='vertical',command=self.canvas.yview)
        self.vertical.grid(row=0,column=1,sticky='ns')
        self.horizontal=ttk.Scrollbar(self,orient='horizontal',command=self.canvas.xview)
        self.horizontal.grid(row=1,column=0,sticky='ew')
        self.canvas.configure(yscrollcommand=self.vertical.set,xscrollcommand=self.horizontal.set)
        self.content=ttk.Frame(self.canvas)
        self.window=self.canvas.create_window(0,0,window=self.content,anchor='nw')
        self.content.bind('<Configure>',self._layout)
        self.canvas.bind('<Configure>',self._layout)

    def _layout(self,_event=None):
        width=max(self.canvas.winfo_width(),self.content.winfo_reqwidth())
        height=max(self.canvas.winfo_height(),self.content.winfo_reqheight())
        self.canvas.itemconfigure(self.window,width=width,height=height)
        self.canvas.configure(scrollregion=(0,0,width,height))
